//
//  MTIAsyncImageView.m
//  MetalPetal
//
//  Created by Yu Ao on 2019/6/12.
//
#if __has_include(<UIKit/UIKit.h>)

#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
#define MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4 0
#else
#define MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4 1
#endif

#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
#import <Metal/MTL4ArgumentTable.h>
#import <Metal/MTL4CommandAllocator.h>
#import <Metal/MTL4CommandBuffer.h>
#import <Metal/MTL4CommandQueue.h>
#import <Metal/MTL4CommitFeedback.h>
#import <Metal/MTL4RenderPass.h>
#import <Metal/MTL4RenderCommandEncoder.h>
#endif
#import "MTIImage.h"
#import "MTIContext+Rendering.h"
#import "MTIContext+Internal.h"
#import "MTIThreadSafeImageView.h"
#import "MTILock.h"
#import "MTIPrint.h"
#import "MTIError.h"
#import "MTIRenderTask.h"
#import "MTIImageRenderingContext.h"
#import "MTIImageRenderingContext+Internal.h"
#import "MTIRenderPipeline.h"
#import "MTIRenderPipelineKernel.h"
#import "MTIVertex.h"
#import "MTIFilter.h"
#import "MTIBuffer.h"

NSString * const MTIImageViewErrorDomain = @"MTIImageViewErrorDomain";


@protocol MTICAMetalLayer

@property(nullable, retain) id<MTLDevice> device;

@property MTLPixelFormat pixelFormat;

@property CGSize drawableSize;

@property(getter=isOpaque) BOOL opaque;

@property CGFloat contentsScale;

@property (nullable) CGColorSpaceRef colorspace;

- (id<CAMetalDrawable>)nextDrawable;

@end


// For simulator < iOS 13
__attribute__((objc_subclassing_restricted))
@interface MTIStubMetalLayer : CALayer <MTICAMetalLayer>

@property (nullable, retain, atomic) id<MTLDevice> device;

@property (atomic) MTLPixelFormat pixelFormat;

@property (atomic) CGSize drawableSize;

@property (nullable) CGColorSpaceRef colorspace;

@end

@implementation MTIStubMetalLayer

- (id<CAMetalDrawable>)nextDrawable {
    return nil;
}

- (CGColorSpaceRef)colorspace {
    return nil;
}

- (void)setColorspace:(CGColorSpaceRef)colorspace {
    
}

@end


@interface CAMetalLayer (MTICAMetalLayerProtocol) <MTICAMetalLayer>

@end

@implementation CAMetalLayer (MTICAMetalLayerProtocol)

@end

@class MTIThreadSafeImageView;
@class MTIThreadSafeImageViewBatchedRenderItem;

@interface MTIContext (MTIThreadSafeImageViewRenderingSupport)

+ (MTIRenderPipelineKernel *)premultiplyAlphaKernel;
+ (MTIRenderPipelineKernel *)passthroughKernel;

@end

static void MTIThreadSafeImageViewInvokeCompletions(NSArray *completions, NSError *error) {
    for (id completion in completions) {
        void (^block)(NSError *) = completion;
        block(error);
    }
}

static NSError *MTIThreadSafeImageViewBatchCancellationError(void) {
    return [NSError errorWithDomain:MTIImageViewErrorDomain
                               code:NSUserCancelledError
                           userInfo:@{NSLocalizedFailureReasonErrorKey: @"The image view was released before its coalesced render request could be submitted."}];
}

static BOOL MTIThreadSafeImageViewSupportsMetal4(id<MTLDevice> device) {
    if (!device) {
        return NO;
    }
    if (@available(ios 26.0, tvos 26.0, maccatalyst 26.0, *)) {
        return [device respondsToSelector:@selector(newMTL4CommandQueue)];
    }
    return NO;
}

static void MTIThreadSafeImageViewComputeDrawableScaling(CGSize imageSize,
                                                         CGSize drawableSize,
                                                         MTIDrawableRenderingResizingMode resizingMode,
                                                         float *widthScaling,
                                                         float *heightScaling) {
    *widthScaling = 1.0f;
    *heightScaling = 1.0f;
    if (drawableSize.width <= 0 || drawableSize.height <= 0 || imageSize.width <= 0 || imageSize.height <= 0) {
        return;
    }
    CGRect bounds = CGRectMake(0, 0, drawableSize.width, drawableSize.height);
    CGRect insetRect = AVMakeRectWithAspectRatioInsideRect(imageSize, bounds);
    switch (resizingMode) {
        case MTIDrawableRenderingResizingModeScale:
            break;
        case MTIDrawableRenderingResizingModeAspect:
            *widthScaling = insetRect.size.width / drawableSize.width;
            *heightScaling = insetRect.size.height / drawableSize.height;
            break;
        case MTIDrawableRenderingResizingModeAspectFill:
            *widthScaling = drawableSize.height / insetRect.size.height;
            *heightScaling = drawableSize.width / insetRect.size.width;
            break;
    }
}

@interface MTIThreadSafeImageViewBatchedRenderItem : NSObject

@property (nonatomic, weak) MTIThreadSafeImageView *view;
@property (nonatomic, strong) MTIContext *context;
@property (nonatomic, strong) MTIImage *image;
@property (nonatomic, strong) MTIImageRenderingContext *renderingContext;
@property (nonatomic, strong) id<MTIImagePromiseResolution> resolution;
@property (nonatomic) MTIDrawableRenderingResizingMode resizingMode;
@property (nonatomic) MTLClearColor clearColor;
@property (nonatomic, copy) NSArray *completions;

@end

@implementation MTIThreadSafeImageViewBatchedRenderItem

@end

static void MTIThreadSafeImageViewFinishBatchedRenderItem(MTIThreadSafeImageViewBatchedRenderItem *item, NSError *error) {
    if (item.resolution) {
        [item.resolution markAsConsumedBy:item.context];
        item.resolution = nil;
    }
    item.renderingContext = nil;
    if (error.code == NSUserCancelledError) {
        [item.context recordPerformanceCounter:@"threadSafeImageView.batch.cancelled" increment:1];
    }
    MTIThreadSafeImageViewInvokeCompletions(item.completions ?: @[], error);
}

#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
@interface MTIThreadSafeImageViewMetal4Presenter : NSObject

- (instancetype)initWithContext:(MTIContext *)context feedbackQueue:(dispatch_queue_t)feedbackQueue;
- (BOOL)isAvailable;
- (BOOL)submitRenderItems:(NSArray<MTIThreadSafeImageViewBatchedRenderItem *> *)items error:(NSError **)error;

@end
#endif

@interface MTIThreadSafeImageViewBatchCoordinator : NSObject

+ (instancetype)sharedCoordinator;
- (void)enqueueView:(MTIThreadSafeImageView *)view;

@end


@interface MTIThreadSafeImageView ()

@property (nonatomic, readonly, strong) id<MTICAMetalLayer> renderLayer;

@property (nonatomic) CGFloat screenScale;

@property (nonatomic) id<CAMetalDrawable> currentDrawable;

@property (nonatomic) id<MTILocking> lock;

@property (nonatomic) CGRect backgroundAccessingBounds;

@property (nonatomic) BOOL currentDrawableValid;

@property (nonatomic) CGSize currentDrawableSize;

@property (nonatomic, strong) NSError *contextCreationError;

@property (nonatomic) BOOL needsRender;

@property (nonatomic) BOOL renderDispatchScheduled;

@property (nonatomic, readonly) NSMutableArray *pendingRenderCompletions;

- (nullable MTIThreadSafeImageViewBatchedRenderItem *)dequeueMetal4BatchedRenderItemIfPossible;

- (void)renderBatchedRenderItemFallback:(MTIThreadSafeImageViewBatchedRenderItem *)item;

- (void)renderImage:(MTIImage *)image
       resizingMode:(MTIDrawableRenderingResizingMode)resizingMode
         clearColor:(MTLClearColor)clearColor
         completion:(void (^)(NSError *))completion;

#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
- (nullable id<CAMetalDrawable>)acquireDrawableForMetal4RenderingWithRenderPassDescriptor:(MTL4RenderPassDescriptor * __autoreleasing *)renderPassDescriptor
                                                                                clearColor:(MTLClearColor)clearColor
                                                                                     error:(NSError **)error;
#endif

@end

#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
@implementation MTIThreadSafeImageViewMetal4Presenter {
    __weak MTIContext *_context;
    dispatch_queue_t _feedbackQueue;
    id<MTL4CommandQueue> _commandQueue;
    NSMutableArray<id<MTL4CommandAllocator>> *_allocatorPool;
}

- (instancetype)initWithContext:(MTIContext *)context feedbackQueue:(dispatch_queue_t)feedbackQueue {
    if (self = [super init]) {
        _context = context;
        _feedbackQueue = feedbackQueue;
        _allocatorPool = [NSMutableArray array];
        NSError *error = nil;
        MTL4CommandQueueDescriptor *descriptor = [[MTL4CommandQueueDescriptor alloc] init];
        descriptor.label = [context.label stringByAppendingString:@".threadSafeImageView.metal4"];
        descriptor.feedbackQueue = feedbackQueue;
        _commandQueue = [context.device newMTL4CommandQueueWithDescriptor:descriptor error:&error];
        if (!_commandQueue && error) {
            MTIPrint(@"MTIThreadSafeImageView Metal 4 queue creation failed: %@", error);
        }
    }
    return self;
}

- (BOOL)isAvailable {
    return _commandQueue != nil;
}

- (id<MTL4CommandAllocator>)dequeueAllocatorWithIndex:(NSUInteger)index error:(NSError **)error {
    if (index < _allocatorPool.count) {
        return _allocatorPool[index];
    }
    id<MTL4CommandAllocator> allocator = [self->_context.device newCommandAllocatorWithDescriptor:[[MTL4CommandAllocatorDescriptor alloc] init] error:error];
    if (allocator) {
        [_allocatorPool addObject:allocator];
    }
    return allocator;
}

- (nullable MTIRenderPipeline *)renderPipelineForItem:(MTIThreadSafeImageViewBatchedRenderItem *)item
                                    outputPixelFormat:(MTLPixelFormat)pixelFormat
                                                error:(NSError **)error {
    MTIRenderPipelineKernel *kernel = item.image.alphaType == MTIAlphaTypeNonPremultiplied ? [MTIContext premultiplyAlphaKernel] : [MTIContext passthroughKernel];
    MTIRenderPipelineKernelConfiguration *configuration = [[MTIRenderPipelineKernelConfiguration alloc] initWithColorAttachmentPixelFormat:pixelFormat];
    return [item.context kernelStateForKernel:kernel configuration:configuration error:error];
}

- (BOOL)submitRenderItems:(NSArray<MTIThreadSafeImageViewBatchedRenderItem *> *)items error:(NSError **)error {
    if (_commandQueue == nil) {
        if (error) {
            *error = [NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorContextNotFound userInfo:@{NSLocalizedFailureReasonErrorKey: @"Metal 4 command queue is not available."}];
        }
        return NO;
    }
    NSMutableArray<id<MTL4CommandBuffer>> *commandBuffers = [NSMutableArray array];
    NSMutableArray<id<MTL4CommandAllocator>> *allocators = [NSMutableArray array];
    NSMutableArray<id<CAMetalDrawable>> *drawables = [NSMutableArray array];
    NSMutableArray<MTIThreadSafeImageViewBatchedRenderItem *> *encodedItems = [NSMutableArray array];
    NSMutableArray<NSArray *> *completionGroups = [NSMutableArray array];
    for (MTIThreadSafeImageViewBatchedRenderItem *item in items) {
        NSError *itemError = nil;
        MTIThreadSafeImageView *view = item.view;
        if (view == nil) {
            MTIThreadSafeImageViewFinishBatchedRenderItem(item, MTIThreadSafeImageViewBatchCancellationError());
            continue;
        }
        id<CAMetalDrawable> drawable = nil;
        MTL4RenderPassDescriptor *renderPassDescriptor = nil;
        drawable = [view acquireDrawableForMetal4RenderingWithRenderPassDescriptor:&renderPassDescriptor clearColor:item.clearColor error:&itemError];
        if (drawable == nil || renderPassDescriptor == nil) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        MTIRenderPipeline *renderPipeline = [self renderPipelineForItem:item outputPixelFormat:drawable.texture.pixelFormat error:&itemError];
        if (!renderPipeline || itemError) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        id<MTLSamplerState> samplerState = [item.context samplerStateWithDescriptor:item.image.samplerDescriptor error:&itemError];
        if (!samplerState || itemError) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        MTIVertex quadVertices[4];
        float widthScaling = 1.0f;
        float heightScaling = 1.0f;
        MTIThreadSafeImageViewComputeDrawableScaling(item.image.size,
                                                     CGSizeMake(drawable.texture.width, drawable.texture.height),
                                                     item.resizingMode,
                                                     &widthScaling,
                                                     &heightScaling);
        quadVertices[0] = MTIVertexMake(-widthScaling, -heightScaling, 0, 1, 0, 1);
        quadVertices[1] = MTIVertexMake(widthScaling, -heightScaling, 0, 1, 1, 1);
        quadVertices[2] = MTIVertexMake(-widthScaling, heightScaling, 0, 1, 0, 0);
        quadVertices[3] = MTIVertexMake(widthScaling, heightScaling, 0, 1, 1, 0);
        MTIDataBuffer *vertexData = [[MTIDataBuffer alloc] initWithBytes:quadVertices length:sizeof(quadVertices) options:0];
        id<MTLBuffer> vertexBuffer = [vertexData bufferForDevice:item.context.device];
        if (!vertexBuffer) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        id<MTL4CommandAllocator> allocator = [self dequeueAllocatorWithIndex:allocators.count error:&itemError];
        if (!allocator || itemError) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        id<MTL4CommandBuffer> commandBuffer = [item.context.device newCommandBuffer];
        if (!commandBuffer) {
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        [commandBuffer beginCommandBufferWithAllocator:allocator];
        id<MTL4RenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (!encoder) {
            [commandBuffer endCommandBuffer];
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        NSError *argumentTableError = nil;
        MTL4ArgumentTableDescriptor *argumentTableDescriptor = [[MTL4ArgumentTableDescriptor alloc] init];
        argumentTableDescriptor.maxBufferBindCount = 1;
        argumentTableDescriptor.maxTextureBindCount = 1;
        argumentTableDescriptor.maxSamplerStateBindCount = 1;
        id<MTL4ArgumentTable> argumentTable = [item.context.device newArgumentTableWithDescriptor:argumentTableDescriptor error:&argumentTableError];
        if (!argumentTable || argumentTableError) {
            [encoder endEncoding];
            [commandBuffer endCommandBuffer];
            [item.context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.fallback" increment:1];
            [view renderBatchedRenderItemFallback:item];
            continue;
        }
        [encoder setViewport:(MTLViewport){0, 0, drawable.texture.width, drawable.texture.height, 0, 1}];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setRenderPipelineState:renderPipeline.state];
        [argumentTable setAddress:vertexBuffer.gpuAddress atIndex:0];
        [argumentTable setTexture:item.resolution.texture.gpuResourceID atIndex:0];
        [argumentTable setSamplerState:samplerState.gpuResourceID atIndex:0];
        [encoder setArgumentTable:argumentTable atStages:MTLRenderStageVertex|MTLRenderStageFragment];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];
        [commandBuffer endCommandBuffer];
        [commandBuffers addObject:commandBuffer];
        [allocators addObject:allocator];
        [drawables addObject:drawable];
        [encodedItems addObject:item];
        [completionGroups addObject:item.completions ?: @[]];
    }
    if (commandBuffers.count == 0) {
        return YES;
    }
    for (id<CAMetalDrawable> drawable in drawables) {
        [_commandQueue waitForDrawable:drawable];
    }
    MTL4CommitOptions *options = [[MTL4CommitOptions alloc] init];
    NSArray *itemsToFinish = [encodedItems copy];
    NSArray *completionsToNotify = [completionGroups copy];
    NSArray *allocatorsToReset = [allocators copy];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        NSError *feedbackError = feedback.error;
        for (NSUInteger index = 0; index < completionsToNotify.count; index += 1) {
            MTIThreadSafeImageViewBatchedRenderItem *item = itemsToFinish[index];
            item.completions = completionsToNotify[index];
            MTIThreadSafeImageViewFinishBatchedRenderItem(item, feedbackError);
        }
        for (id<MTL4CommandAllocator> allocator in allocatorsToReset) {
            [allocator reset];
        }
    }];
    NSUInteger commandBufferCount = commandBuffers.count;
    id<MTL4CommandBuffer> stackCommandBuffers[commandBufferCount];
    for (NSUInteger index = 0; index < commandBufferCount; index += 1) {
        stackCommandBuffers[index] = commandBuffers[index];
    }
    [_commandQueue commit:stackCommandBuffers count:commandBufferCount options:options];
    for (id<CAMetalDrawable> drawable in drawables) {
        [_commandQueue signalDrawable:drawable];
        [drawable present];
    }
    [self->_context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.commit" increment:1];
    [self->_context recordPerformanceCounter:@"threadSafeImageView.batch.metal4.items" increment:commandBufferCount];
    return YES;
}

@end
#endif

@implementation MTIThreadSafeImageViewBatchCoordinator {
    id<MTILocking> _lock;
    NSHashTable<MTIThreadSafeImageView *> *_pendingViews;
    BOOL _flushScheduled;
    dispatch_queue_t _queue;
    NSMapTable<MTIContext *, id> *_presenters;
}

+ (instancetype)sharedCoordinator {
    static MTIThreadSafeImageViewBatchCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[MTIThreadSafeImageViewBatchCoordinator alloc] init];
    });
    return coordinator;
}

- (instancetype)init {
    if (self = [super init]) {
        _lock = MTILockCreate();
        _pendingViews = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("com.metalpetal.thread-safe-image-view.batch", DISPATCH_QUEUE_SERIAL);
        _presenters = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    return self;
}

- (void)enqueueView:(MTIThreadSafeImageView *)view {
    [_lock lock];
    [_pendingViews addObject:view];
    BOOL shouldScheduleFlush = !_flushScheduled;
    if (shouldScheduleFlush) {
        _flushScheduled = YES;
    }
    [_lock unlock];
    if (!shouldScheduleFlush) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(self->_queue, ^{
            [self flushPendingViews];
        });
    });
}

- (nullable id)presenterForContext:(MTIContext *)context {
    id presenter = [_presenters objectForKey:context];
    if (presenter) {
        return presenter;
    }
#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
    if (@available(iOS 26.0, tvOS 26.0, macCatalyst 26.0, *)) {
        if (MTIThreadSafeImageViewSupportsMetal4(context.device)) {
            presenter = [[MTIThreadSafeImageViewMetal4Presenter alloc] initWithContext:context feedbackQueue:_queue];
            if ([presenter isAvailable]) {
                [_presenters setObject:presenter forKey:context];
                return presenter;
            }
        }
    }
#endif
    return nil;
}

- (void)flushPendingViews {
    [_lock lock];
    NSArray<MTIThreadSafeImageView *> *views = _pendingViews.allObjects;
    [_pendingViews removeAllObjects];
    _flushScheduled = NO;
    [_lock unlock];
    NSMapTable<MTIContext *, NSMutableArray<MTIThreadSafeImageViewBatchedRenderItem *> *> *itemsByContext =
    [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                          valueOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    for (MTIThreadSafeImageView *view in views) {
        MTIThreadSafeImageViewBatchedRenderItem *item = [view dequeueMetal4BatchedRenderItemIfPossible];
        if (!item) {
            continue;
        }
        NSMutableArray *items = [itemsByContext objectForKey:item.context];
        if (!items) {
            items = [NSMutableArray array];
            [itemsByContext setObject:items forKey:item.context];
        }
        [items addObject:item];
    }
    for (MTIContext *context in itemsByContext.keyEnumerator) {
        NSMutableArray<MTIThreadSafeImageViewBatchedRenderItem *> *items = [itemsByContext objectForKey:context];
        id presenter = [self presenterForContext:context];
        NSError *error = nil;
#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
        if (presenter && [presenter submitRenderItems:items error:&error]) {
            continue;
        }
#else
        (void)presenter;
        (void)error;
#endif
        for (MTIThreadSafeImageViewBatchedRenderItem *item in items) {
            MTIThreadSafeImageView *view = item.view;
            if (view) {
                [item.context recordPerformanceCounter:@"threadSafeImageView.batch.classic.fallback" increment:1];
                [view renderBatchedRenderItemFallback:item];
            } else {
                MTIThreadSafeImageViewFinishBatchedRenderItem(item, MTIThreadSafeImageViewBatchCancellationError());
            }
        }
    }
}

@end

@implementation MTIThreadSafeImageView
@synthesize context = _context;
@synthesize image = _image;
@synthesize clearColor = _clearColor;
@synthesize resizingMode = _resizingMode;
@synthesize renderSchedulingMode = _renderSchedulingMode;
@synthesize prefersMetal4BatchedSubmission = _prefersMetal4BatchedSubmission;

+ (Class)layerClass {
#if TARGET_OS_SIMULATOR
    if (@available(iOS 13.0, *)) {
        return CAMetalLayer.class;
    } else {
        return MTIStubMetalLayer.class;
    }
#else
    return CAMetalLayer.class;
#endif
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        [self setupImageView];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self setupImageView];
    }
    return self;
}

- (void)setupImageView {
    _renderLayer = (id)self.layer;
    _resizingMode = MTIDrawableRenderingResizingModeAspect;
    _automaticallyCreatesContext = YES;
    _renderLayer.device = nil;
    _currentDrawableSize = _renderLayer.drawableSize;
    _lock = MTILockCreate();
    _pendingRenderCompletions = [NSMutableArray array];
    _renderSchedulingMode = MTIThreadSafeImageViewRenderSchedulingModeImmediate;
    _prefersMetal4BatchedSubmission = NO;
    self.opaque = YES;
}

- (void)setOpaque:(BOOL)opaque {
    NSAssert(NSThread.isMainThread, @"");
    [_lock lock];
    BOOL oldOpaque = [super isOpaque];
    [super setOpaque:opaque];
    _renderLayer.opaque = opaque;
    if (oldOpaque != opaque) {
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_lock lock];
    if (self.window.screen) {
        _screenScale = MIN(self.window.screen.nativeScale, self.window.screen.scale);
    } else {
        _screenScale = 1.0;
    }
    [_lock unlock];
}

- (void)setContext:(MTIContext *)context {
    [_lock lock];
    _context = context;
    _renderLayer.device = context.device;
    [self requestRenderLockedWithCompletion:nil];
    [_lock unlock];
}

- (MTIContext *)context {
    [_lock lock];
    [self setupContextIfNeeded];
    MTIContext *c = _context;
    [_lock unlock];
    return c;
}

- (void)setupContextIfNeeded {
    NSAssert([_lock tryLock] == NO, @"");
    if (!_context && !_contextCreationError && _automaticallyCreatesContext) {
        NSError *error;
        _context = [[MTIContext alloc] initWithDevice:MTLCreateSystemDefaultDevice() error:&error];
        if (error) {
            _contextCreationError = error;
        }
        _renderLayer.device = _context.device;
    }
}

- (void)setColorPixelFormat:(MTLPixelFormat)colorPixelFormat {
    [_lock lock];
    if (_renderLayer.pixelFormat != colorPixelFormat) {
        _renderLayer.pixelFormat = colorPixelFormat;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (MTLPixelFormat)colorPixelFormat {
    [_lock lock];
    MTLPixelFormat format = _renderLayer.pixelFormat;
    [_lock unlock];
    return format;
}

- (void)setColorSpace:(CGColorSpaceRef)colorSpace {
    [_lock lock];
    if (_renderLayer.colorspace != colorSpace) {
        _renderLayer.colorspace = colorSpace;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (CGColorSpaceRef)colorSpace {
    [_lock lock];
    CGColorSpaceRef colorspace = _renderLayer.colorspace;
    [_lock unlock];
    return colorspace;
}

- (void)setClearColor:(MTLClearColor)clearColor {
    [_lock lock];
    if (_clearColor.red != clearColor.red ||
        _clearColor.green != clearColor.green ||
        _clearColor.blue != clearColor.blue ||
        _clearColor.alpha != clearColor.alpha
        ) {
        _clearColor = clearColor;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (MTLClearColor)clearColor {
    [_lock lock];
    MTLClearColor color = _clearColor;
    [_lock unlock];
    return color;
}

- (void)setImage:(MTIImage *)image {
    [self setImage:image renderCompletion:nil];
}

- (void)setImage:(MTIImage *)image renderCompletion:(void (^)(NSError *))renderCompletion {
    [_lock lock];
    if (_image != image) {
        _image = image;
        [self requestRenderLockedWithCompletion:renderCompletion];
    } else {
        [_lock unlock];
        if (renderCompletion) {
            renderCompletion([NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorSameImage userInfo:nil]);
        }
        return;
    }
    [_lock unlock];
}

- (MTIImage *)image {
    [_lock lock];
    MTIImage *image = _image;
    [_lock unlock];
    return image;
}

- (void)setResizingMode:(MTIDrawableRenderingResizingMode)resizingMode {
    [_lock lock];
    if (_resizingMode != resizingMode) {
        _resizingMode = resizingMode;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (void)setRenderSchedulingMode:(MTIThreadSafeImageViewRenderSchedulingMode)renderSchedulingMode {
    [_lock lock];
    if (_renderSchedulingMode != renderSchedulingMode) {
        _renderSchedulingMode = renderSchedulingMode;
        if (renderSchedulingMode == MTIThreadSafeImageViewRenderSchedulingModeImmediate &&
            (_needsRender || _pendingRenderCompletions.count > 0)) {
            [self requestRenderLockedWithCompletion:nil];
        }
    }
    [_lock unlock];
}

- (void)setPrefersMetal4BatchedSubmission:(BOOL)prefersMetal4BatchedSubmission {
    [_lock lock];
    if (_prefersMetal4BatchedSubmission != prefersMetal4BatchedSubmission) {
        _prefersMetal4BatchedSubmission = prefersMetal4BatchedSubmission;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

- (MTIDrawableRenderingResizingMode)resizingMode {
    [_lock lock];
    MTIDrawableRenderingResizingMode resizingMode = _resizingMode;
    [_lock unlock];
    return resizingMode;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    [_lock lock];
    if (!CGRectEqualToRect(_backgroundAccessingBounds, self.bounds)) {
        _backgroundAccessingBounds = self.bounds;
        [self requestRenderLockedWithCompletion:nil];
    }
    [_lock unlock];
}

// locking access

- (void)requestRenderLockedWithCompletion:(void (^)(NSError *))completion {
    NSAssert([_lock tryLock] == NO, @"");
    
    if (_renderSchedulingMode == MTIThreadSafeImageViewRenderSchedulingModeImmediate) {
        NSArray *pendingCompletions = [_pendingRenderCompletions copy];
        [_pendingRenderCompletions removeAllObjects];
        _needsRender = NO;
        void (^wrappedCompletion)(NSError *) = completion;
        if (pendingCompletions.count > 0) {
            void (^currentCompletion)(NSError *) = [completion copy];
            wrappedCompletion = ^(NSError *error) {
                for (void (^pendingCompletion)(NSError *) in pendingCompletions) {
                    pendingCompletion(error);
                }
                if (currentCompletion) {
                    currentCompletion(error);
                }
            };
        }
        [self renderImage:_image completion:wrappedCompletion];
        return;
    }
    
    if (completion) {
        [_pendingRenderCompletions addObject:[completion copy]];
    }
    _needsRender = YES;
    if (_renderDispatchScheduled) {
        return;
    }
    
    _renderDispatchScheduled = YES;
    [[MTIThreadSafeImageViewBatchCoordinator sharedCoordinator] enqueueView:self];
}

- (void)renderImage:(MTIImage *)image completion:(void (^)(NSError *))completion {
    NSAssert([_lock tryLock] == NO, @"");
    [self renderImage:image resizingMode:_resizingMode clearColor:_clearColor completion:completion];
}

- (void)renderImage:(MTIImage *)image
       resizingMode:(MTIDrawableRenderingResizingMode)resizingMode
         clearColor:(MTLClearColor)clearColor
         completion:(void (^)(NSError *))completion {
    NSAssert([_lock tryLock] == NO, @"");
    
    [self setupContextIfNeeded];
    
    MTIContext *context = self -> _context;
    if (!context) {
        if (completion) {
            completion(_contextCreationError ?: [NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorContextNotFound userInfo:nil]);
        }
        return;
    }
    
    [self updateContentScaleFactor];
    
    MTIImage *imageToRender = image;
    if (imageToRender.cachePolicy == MTIImageCachePolicyPersistent) {
        MTIImage *bufferedImage = [context renderedBufferForImage:imageToRender];
        if (bufferedImage) {
            imageToRender = bufferedImage;
        }
    }
    
    [self invalidateCurrentDrawable];
    
    MTIDrawableRenderingRequest *request = [[MTIDrawableRenderingRequest alloc] initWithDrawableProvider:self resizingMode:resizingMode];

    if (imageToRender) {
        NSError *error;
        [context startTaskToRenderImage:imageToRender
                  toDrawableWithRequest:request
                                  error:&error
                             completion:^(MTIRenderTask * _Nonnull task) {
                                 if (completion) {
                                     completion(task.error);
                                 }
                             }];
        if (error) {
            MTIPrint(@"%@: Failed to render image %@ - %@",self,imageToRender,error);
            if (completion) {
                completion(error);
            }
        }
    } else {
        //Clear current drawable.
        MTLRenderPassDescriptor *renderPassDescriptor = [self renderPassDescriptorForRequest:request];
        id<MTLDrawable> drawable = [self drawableForRequest:request];
        if (renderPassDescriptor && drawable) {
            renderPassDescriptor.colorAttachments[0].clearColor = clearColor;
            id<MTLCommandBuffer> commandBuffer = [context.commandQueue commandBuffer];
            id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
            [commandEncoder endEncoding];
            [commandBuffer presentDrawable:drawable];
            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                if (completion) {
                    completion(cb.error);
                }
            }];
            [commandBuffer commit];
        } else {
            if (completion) {
                completion(MTIErrorCreate(MTIErrorEmptyDrawable, nil));
            }
        }
    }
}

- (nullable MTIThreadSafeImageViewBatchedRenderItem *)dequeueMetal4BatchedRenderItemIfPossible {
    [_lock lock];
    _renderDispatchScheduled = NO;
    if (!_needsRender) {
        [_lock unlock];
        return nil;
    }
    _needsRender = NO;
    [self setupContextIfNeeded];
    MTIContext *context = _context;
    NSArray *completions = [_pendingRenderCompletions copy];
    [_pendingRenderCompletions removeAllObjects];
    if (!context) {
        NSError *error = _contextCreationError ?: [NSError errorWithDomain:MTIImageViewErrorDomain code:MTIImageViewErrorContextNotFound userInfo:nil];
        [_lock unlock];
        MTIThreadSafeImageViewInvokeCompletions(completions, error);
        return nil;
    }
    [self updateContentScaleFactor];
    BOOL shouldDeferBatchedRender =
    (self.window == nil ||
     _backgroundAccessingBounds.size.width <= 0 ||
     _backgroundAccessingBounds.size.height <= 0 ||
     _currentDrawableSize.width < 16.0 ||
     _currentDrawableSize.height < 16.0);
    if (shouldDeferBatchedRender) {
        _needsRender = YES;
        if (completions.count > 0) {
            [_pendingRenderCompletions addObjectsFromArray:completions];
        }
        [_lock unlock];
        return nil;
    }
    MTIImage *image = _image;
    MTIImage *bufferedImage = nil;
    if (image.cachePolicy == MTIImageCachePolicyPersistent) {
        bufferedImage = [context renderedBufferForImage:image];
    }
    if (bufferedImage &&
        _prefersMetal4BatchedSubmission &&
        MTIThreadSafeImageViewSupportsMetal4(context.device)) {
        MTIImageRenderingContext *renderingContext = [[MTIImageRenderingContext alloc] initWithContext:context];
        NSError *resolutionError = nil;
        id<MTIImagePromiseResolution> resolution = [renderingContext resolutionForImage:bufferedImage error:&resolutionError];
        if (resolution) {
            MTIThreadSafeImageViewBatchedRenderItem *item = [[MTIThreadSafeImageViewBatchedRenderItem alloc] init];
            item.view = self;
            item.context = context;
            item.image = bufferedImage;
            item.renderingContext = renderingContext;
            item.resolution = resolution;
            item.resizingMode = _resizingMode;
            item.clearColor = _clearColor;
            item.completions = completions;
            [context recordPerformanceCounter:@"threadSafeImageView.batch.candidate" increment:1];
            [_lock unlock];
            return item;
        }
    }
    MTIDrawableRenderingResizingMode resizingMode = _resizingMode;
    MTLClearColor clearColor = _clearColor;
    [self renderImage:image resizingMode:resizingMode clearColor:clearColor completion:^(NSError *error) {
        MTIThreadSafeImageViewInvokeCompletions(completions, error);
    }];
    [_lock unlock];
    return nil;
}

- (void)renderBatchedRenderItemFallback:(MTIThreadSafeImageViewBatchedRenderItem *)item {
    [_lock lock];
    [self renderImage:item.image resizingMode:item.resizingMode clearColor:item.clearColor completion:^(NSError *error) {
        MTIThreadSafeImageViewFinishBatchedRenderItem(item, error);
    }];
    [_lock unlock];
}

#if MTI_THREAD_SAFE_IMAGE_VIEW_CAN_COMPILE_METAL4
- (nullable id<CAMetalDrawable>)acquireDrawableForMetal4RenderingWithRenderPassDescriptor:(MTL4RenderPassDescriptor * __autoreleasing *)renderPassDescriptor
                                                                                clearColor:(MTLClearColor)clearColor
                                                                                     error:(NSError **)error {
    [_lock lock];
    [self invalidateCurrentDrawable];
    [self requestNextDrawableIfNeeded];
    id<CAMetalDrawable> drawable = _currentDrawable;
    if (!drawable) {
        [_lock unlock];
        if (error) {
            *error = MTIErrorCreate(MTIErrorEmptyDrawable, nil);
        }
        return nil;
    }
    if (drawable.texture == nil) {
        [_lock unlock];
        if (error) {
            *error = MTIErrorCreate(MTIErrorEmptyDrawableTexture, @{NSLocalizedFailureReasonErrorKey: @"Rendering image to drawable: no texture found on color attachment 0. This could happen when the drawable size is less than 16x16 pixels on some devices."});
        }
        return nil;
    }
    MTL4RenderPassDescriptor *descriptor = [[MTL4RenderPassDescriptor alloc] init];
    descriptor.colorAttachments[0].texture = drawable.texture;
    descriptor.colorAttachments[0].clearColor = clearColor;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    [_lock unlock];
    if (renderPassDescriptor) {
        *renderPassDescriptor = descriptor;
    }
    return drawable;
}
#endif

- (void)updateContentScaleFactor {
    NSAssert([_lock tryLock] == NO, @"");

    __auto_type renderLayer = _renderLayer;
    if (_backgroundAccessingBounds.size.width > 0 && _backgroundAccessingBounds.size.height > 0 && _image && _image.size.width > 0 && _image.size.height > 0) {
        CGSize imageSize = _image.size;
        CGFloat widthScale = imageSize.width/_backgroundAccessingBounds.size.width;
        CGFloat heightScale = imageSize.height/_backgroundAccessingBounds.size.height;
        CGFloat nativeScale = _screenScale;
        CGFloat scale = MAX(MIN(MAX(widthScale,heightScale),nativeScale), 1.0);
        CGSize drawableSize = CGSizeMake(_backgroundAccessingBounds.size.width * scale, _backgroundAccessingBounds.size.height * scale);
        if (ABS(renderLayer.contentsScale - scale) > 0.00001 || !CGSizeEqualToSize(drawableSize, _currentDrawableSize)) {
            renderLayer.contentsScale = scale;
            renderLayer.drawableSize = drawableSize;
            _currentDrawableSize = drawableSize;
        }
    }
}

- (void)invalidateCurrentDrawable {
    NSAssert([_lock tryLock] == NO, @"");
    _currentDrawableValid = NO;
}

- (void)requestNextDrawableIfNeeded {
    NSAssert([_lock tryLock] == NO, @"");
    if (!_currentDrawableValid) {
        _currentDrawable = _renderLayer.nextDrawable;
        _currentDrawableValid = YES;
    }
}

- (id<MTLDrawable>)drawableForRequest:(MTIDrawableRenderingRequest *)request {
    NSAssert([_lock tryLock] == NO, @"");
    [self requestNextDrawableIfNeeded];
    return _currentDrawable;
}

- (MTLRenderPassDescriptor *)renderPassDescriptorForRequest:(MTIDrawableRenderingRequest *)request {
    NSAssert([_lock tryLock] == NO, @"");
    [self requestNextDrawableIfNeeded];
    MTLRenderPassDescriptor *descriptor = [[MTLRenderPassDescriptor alloc] init];
    descriptor.colorAttachments[0].texture = _currentDrawable.texture;
    descriptor.colorAttachments[0].clearColor = _clearColor;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return descriptor;
}

@end

#endif

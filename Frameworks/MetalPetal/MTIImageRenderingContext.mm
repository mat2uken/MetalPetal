//
//  MTIImageRenderingContext.m
//  Pods
//
//  Created by YuAo on 25/06/2017.
//
//

#import "MTIImageRenderingContext+Internal.h"
#import "MTIContext+Internal.h"
#import "MTIImage+Promise.h"
#import "MTIError.h"
#import "MTIPrint.h"
#import "MTIRenderGraphOptimization.h"
#import "MTIImagePromiseDebug.h"
#import "MTIDefer.h"

#include <unordered_map>
#include <vector>
#include <memory>
#include <cstdint>
#include <utility>

namespace MTIImageRendering {
    struct ObjcPointerIdentityEqual {
        bool operator()(const id s1, const id s2) const {
            return (s1 == s2);
        }
    };
    struct ObjcPointerHash {
        size_t operator()(const id pointer) const {
            auto addr = reinterpret_cast<uintptr_t>(pointer);
            #if SIZE_MAX < UINTPTR_MAX
            addr %= SIZE_MAX; /* truncate the address so it is small enough to fit in a size_t */
            #endif
            return addr;
        }
    };
};

class MTIImageRenderingDependencyGraph {
    
private:
    class PromiseDependents {
    public:
        PromiseDependents() = default;
        
        PromiseDependents(const PromiseDependents &other):
        _dependentCount(other._dependentCount),
        _dependents(other._dependents) {
        }
        
        void addDependent(id<MTIImagePromise> dependent) {
            _dependents[dependent] += 1;
            _dependentCount += 1;
        }
        
        NSInteger dependentCount() const {
            return _dependentCount;
        }
        
        void removeDependent(id<MTIImagePromise> dependent) {
            auto iterator = _dependents.find(dependent);
            NSCAssert(iterator != _dependents.end(), @"Dependent not found in promise's dependents table.");
            if (iterator != _dependents.end()) {
                iterator->second -= 1;
                _dependentCount -= 1;
                if (iterator->second == 0) {
                    _dependents.erase(iterator);
                }
            }
        }
        
    private:
        NSInteger _dependentCount = 0;
        std::unordered_map<__unsafe_unretained id<MTIImagePromise>, NSUInteger, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _dependents;
    };
    
	    std::unordered_map<__unsafe_unretained id<MTIImagePromise>, std::shared_ptr<PromiseDependents>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _promiseDenpendentsCountTable;
	    
public:
    
    MTIImageRenderingDependencyGraph() = default;
    
    MTIImageRenderingDependencyGraph(const MTIImageRenderingDependencyGraph &other) {
        for (const auto &entry : other._promiseDenpendentsCountTable) {
            _promiseDenpendentsCountTable.insert(std::make_pair(entry.first, std::make_shared<PromiseDependents>(*entry.second)));
        }
    }
	    
    void addDependenciesForImage(MTIImage *image) {
        auto dependencies = image.promise.dependencies;
        for (MTIImage *dependency in dependencies) {
            auto promise = dependency.promise;
            auto iterator = _promiseDenpendentsCountTable.find(promise);
            if (iterator == _promiseDenpendentsCountTable.end()) {
                auto dependents = std::make_shared<PromiseDependents>();
                dependents->addDependent(image.promise);
                _promiseDenpendentsCountTable.insert(std::make_pair(promise, dependents));
                this -> addDependenciesForImage(dependency);
            } else {
                iterator->second->addDependent(image.promise);
            }
        }
    }
    
    NSInteger dependentCountForPromise(id<MTIImagePromise> promise) const {
        NSCAssert(_promiseDenpendentsCountTable.count(promise) > 0, @"Promise: %@ is not in this dependency graph.", promise);
        return _promiseDenpendentsCountTable.at(promise) -> dependentCount();
    }
    
    void removeDependentForPromise(id<MTIImagePromise> dependent, id<MTIImagePromise> promise) {
        auto dependents = _promiseDenpendentsCountTable[promise];
        NSCAssert(dependents != nullptr, @"Dependents not found.");
        dependents->removeDependent(dependent);
    }
};

__attribute__((objc_subclassing_restricted))
@interface MTITransientImagePromiseResolution: NSObject <MTIImagePromiseResolution>

@property (nonatomic,copy) void (^invalidationHandler)(id);

@end

@implementation MTITransientImagePromiseResolution

@synthesize texture = _texture;

- (instancetype)initWithTexture:(id<MTLTexture>)texture invalidationHandler:(void (^)(id))invalidationHandler {
    if (self = [super init]) {
        _invalidationHandler = [invalidationHandler copy];
        _texture = texture;
    }
    return self;
}

- (void)markAsConsumedBy:(id)consumer {
    self.invalidationHandler(consumer);
    self.invalidationHandler = nil;
}

- (void)dealloc {
    NSAssert(self.invalidationHandler == nil, @"");
}

@end

__attribute__((objc_subclassing_restricted))
@interface MTIPersistImageResolutionHolder : NSObject

@property (nonatomic,strong) MTIImagePromiseRenderTarget *renderTarget;

@end

@implementation MTIPersistImageResolutionHolder

- (instancetype)initWithRenderTarget:(MTIImagePromiseRenderTarget *)renderTarget {
    if (self = [super init]) {
        _renderTarget = renderTarget;
        [renderTarget retainTexture];
    }
    return self;
}

- (void)dealloc {
    [_renderTarget releaseTexture];
}

@end

NSString * const MTIContextImagePersistentResolutionHolderTableName = @"MTIContextImagePersistentResolutionHolderTable";

MTIContextImageAssociatedValueTableName const MTIContextImagePersistentResolutionHolderTable = MTIContextImagePersistentResolutionHolderTableName;

NSString * const MTIContextPromiseRenderGraphStateTableName = @"MTIContextPromiseRenderGraphStateTable";

MTIContextPromiseAssociatedValueTableName const MTIContextPromiseRenderGraphStateTable = MTIContextPromiseRenderGraphStateTableName;

NSString * const MTIContextImageSamplerStateTableName = @"MTIContextImageSamplerStateTable";

MTIContextImageAssociatedValueTableName const MTIContextImageSamplerStateTable = MTIContextImageSamplerStateTableName;

__attribute__((objc_subclassing_restricted))
@interface MTIRenderGraphState : NSObject

@property (nonatomic, unsafe_unretained, readonly) id<MTIImagePromise> rootPromise;

- (instancetype)initWithAssociationPromise:(id<MTIImagePromise>)associationPromise rootPromise:(id<MTIImagePromise>)rootPromise rootImage:(MTIImage *)rootImage;

- (MTIImageRenderingDependencyGraph *)newDependencyGraph;

- (void)enumerateDependencyImagesInResolveOrderUsingBlock:(void (^)(MTIImage *image, BOOL *stop))block;

- (MTIImage *)rootResolutionImageForImage:(MTIImage *)image;

@end

@implementation MTIRenderGraphState {
    id<MTIImagePromise> _ownedRootPromise;
    MTIImageRenderingDependencyGraph *_dependencyGraphTemplate;
    std::vector<__unsafe_unretained MTIImage *> _orderedDependencyImages;
}

- (instancetype)initWithAssociationPromise:(id<MTIImagePromise>)associationPromise rootPromise:(id<MTIImagePromise>)rootPromise rootImage:(MTIImage *)rootImage {
    if (self = [super init]) {
        _rootPromise = rootPromise;
        if (rootPromise != associationPromise) {
            _ownedRootPromise = rootPromise;
        }
        _dependencyGraphTemplate = new MTIImageRenderingDependencyGraph();
        _dependencyGraphTemplate->addDependenciesForImage(rootImage);
        NSMapTable<id<MTIImagePromise>, id> *visitedPromises = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory|NSMapTableObjectPointerPersonality valueOptions:NSMapTableStrongMemory];
        [self appendResolveOrderForImage:rootImage visitedPromises:visitedPromises];
    }
    return self;
}

- (void)dealloc {
    delete _dependencyGraphTemplate;
}

- (MTIImageRenderingDependencyGraph *)newDependencyGraph {
    return new MTIImageRenderingDependencyGraph(*_dependencyGraphTemplate);
}

- (void)appendResolveOrderForImage:(MTIImage *)image visitedPromises:(NSMapTable<id<MTIImagePromise>, id> *)visitedPromises {
    if ([visitedPromises objectForKey:image.promise]) {
        return;
    }
    [visitedPromises setObject:image.promise forKey:image.promise];
    for (MTIImage *dependency in image.promise.dependencies) {
        [self appendResolveOrderForImage:dependency visitedPromises:visitedPromises];
    }
    if (image.promise != _rootPromise) {
        _orderedDependencyImages.push_back(image);
    }
}

- (void)enumerateDependencyImagesInResolveOrderUsingBlock:(void (^)(MTIImage *image, BOOL *stop))block {
    BOOL stop = NO;
    for (size_t index = 0; index < _orderedDependencyImages.size(); index += 1) {
        MTIImage *image = _orderedDependencyImages[index];
        block(image, &stop);
        if (stop) {
            break;
        }
    }
}

- (MTIImage *)rootResolutionImageForImage:(MTIImage *)image {
    if (_ownedRootPromise) {
        return [[MTIImage alloc] initWithPromise:_ownedRootPromise samplerDescriptor:image.samplerDescriptor cachePolicy:image.cachePolicy];
    }
    return image;
}

@end

@interface MTIImageRenderingContext () {
    std::unordered_map<__unsafe_unretained id<MTIImagePromise>, MTIImagePromiseRenderTarget __strong *, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _resolvedPromises;
    
    MTIImageRenderingDependencyGraph *_dependencyGraph;
    
    std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLTexture>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _currentDependencyResolutionMap;
    
    std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLSamplerState>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _currentDependencySamplerStateMap;
    
    __unsafe_unretained id<MTIImagePromise> _currentResolvingPromise;
}

@end

@implementation MTIImageRenderingContext

- (void)dealloc {
    delete _dependencyGraph;
    
    if (self.commandBuffer.status == MTLCommandBufferStatusNotEnqueued || self.commandBuffer.status == MTLCommandBufferStatusEnqueued) {
        [self.commandBuffer commit];
    }
}

- (instancetype)initWithContext:(MTIContext *)context {
    if (self = [super init]) {
        _context = context;
        _commandBuffer = [context.commandQueue commandBuffer];
        _dependencyGraph = NULL;
    }
    return self;
}

- (id<MTLTexture>)resolvedTextureForImage:(MTIImage *)image {
    auto promise = _currentResolvingPromise;
    NSAssert(promise != nil, @"");
    auto result = _currentDependencyResolutionMap[image];
    if (!result || !promise) {
        [NSException raise:NSInternalInconsistencyException format:@"Do not query resolved texture for image which is not the current resolving promise's dependency. (Promise: %@, Image: %@)", promise, image];
    }
    return result;
}

- (id<MTLSamplerState>)resolvedSamplerStateForImage:(MTIImage *)image {
    auto promise = _currentResolvingPromise;
    NSAssert(promise != nil, @"");
    auto result = _currentDependencySamplerStateMap[image];
    if (!result || !promise) {
        [NSException raise:NSInternalInconsistencyException format:@"Do not query resolved sampler state for image which is not the current resolving promise's dependency. (Promise: %@, Image: %@)", promise, image];
    }
    return result;
}

- (void)consumeRenderTarget:(MTIImagePromiseRenderTarget *)renderTarget forPromise:(id<MTIImagePromise>)promise consumer:(id)consumer {
    _dependencyGraph -> removeDependentForPromise(consumer, promise);
    if (_dependencyGraph -> dependentCountForPromise(promise) == 0) {
        [renderTarget releaseTexture];
    }
}

- (nullable id<MTLSamplerState>)samplerStateForImage:(MTIImage *)image error:(NSError * __autoreleasing *)error {
    id<MTLSamplerState> samplerState = [self.context valueForImage:image inTable:MTIContextImageSamplerStateTable];
    [self.context recordPerformanceCounter:(samplerState ? @"cache.imageSampler.hit" : @"cache.imageSampler.miss") increment:1];
    if (samplerState) {
        return samplerState;
    }
    samplerState = [self.context samplerStateWithDescriptor:image.samplerDescriptor error:error];
    if (samplerState) {
        [self.context setValue:samplerState forImage:image inTable:MTIContextImageSamplerStateTable];
    }
    return samplerState;
}

- (nullable MTIImagePromiseRenderTarget *)resolveRenderTargetForImage:(MTIImage *)image error:(NSError * __autoreleasing *)inOutError {
    if (image == nil) {
        [NSException raise:NSInvalidArgumentException format:@"%@: Application is requesting a resolution of a nil image.", self];
    }
    
    if (!_dependencyGraph) {
        CFTimeInterval startTime = CFAbsoluteTimeGetCurrent();
        @MTI_DEFER {
            [self.context recordPerformanceCounter:@"rendergraph.rootResolution.count" increment:1];
            [self.context recordPerformanceDuration:@"rendergraph.rootResolution.duration" duration:(CFAbsoluteTimeGetCurrent() - startTime)];
        };
        id<MTIImagePromise> promise = image.promise;
        CFTimeInterval graphStateStartTime = CFAbsoluteTimeGetCurrent();
        MTIRenderGraphState *renderGraphState = [self.context valueForPromise:image.promise inTable:MTIContextPromiseRenderGraphStateTable];
        [self.context recordPerformanceCounter:(renderGraphState ? @"rendergraph.state.hit" : @"rendergraph.state.miss") increment:1];
        if (!renderGraphState) {
            MTIImage *rootImage = image;
            if (self.context.isRenderGraphOptimizationEnabled) {
                id<MTIImagePromise> optimizedPromise = [MTIRenderGraphOptimizer promiseByOptimizingRenderGraphOfPromise:promise];
                promise = optimizedPromise;
                rootImage = [[MTIImage alloc] initWithPromise:optimizedPromise samplerDescriptor:image.samplerDescriptor cachePolicy:image.cachePolicy];
            }
            renderGraphState = [[MTIRenderGraphState alloc] initWithAssociationPromise:image.promise rootPromise:promise rootImage:rootImage];
            [self.context setValue:renderGraphState forPromise:image.promise inTable:MTIContextPromiseRenderGraphStateTable];
        }
        promise = renderGraphState.rootPromise;
        _dependencyGraph = [renderGraphState newDependencyGraph];
        [self.context recordPerformanceDuration:@"rendergraph.state.duration" duration:(CFAbsoluteTimeGetCurrent() - graphStateStartTime)];
        
        __block NSError *error = nil;
        [renderGraphState enumerateDependencyImagesInResolveOrderUsingBlock:^(MTIImage *dependencyImage, BOOL *stop) {
            if (![self resolvePreparedRenderTargetForImage:dependencyImage error:&error]) {
                *stop = YES;
            }
        }];
        
        MTIImage *rootResolutionImage = [renderGraphState rootResolutionImageForImage:image];
        MTIImagePromiseRenderTarget *renderTarget = nil;
        if (!error) {
            renderTarget = [self resolvePreparedRenderTargetForImage:rootResolutionImage error:&error];
        }
        if (error) {
            if (inOutError) {
                *inOutError = error;
            }
            MTIPrint(@"An error occurred while resolving promise: %@ for image: %@.\n%@", promise, image, error);
            for (auto entry : _resolvedPromises) {
                if (_dependencyGraph -> dependentCountForPromise(entry.first) != 0) {
                    [entry.second releaseTexture];
                }
            }
            return nil;
        }
        
        if (image.cachePolicy == MTIImageCachePolicyPersistent && rootResolutionImage != image) {
            MTIPersistImageResolutionHolder *persistResolution = [self.context valueForImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
            if (!persistResolution) {
                persistResolution = [[MTIPersistImageResolutionHolder alloc] initWithRenderTarget:renderTarget];
                [self.context setValue:persistResolution forImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
            }
        }
        
        return renderTarget;
    }
    
    return [self resolvePreparedRenderTargetForImage:image error:inOutError];
}

- (nullable MTIImagePromiseRenderTarget *)resolvePreparedRenderTargetForImage:(MTIImage *)image error:(NSError * __autoreleasing *)inOutError {
    if (image == nil) {
        [NSException raise:NSInvalidArgumentException format:@"%@: Application is requesting a resolution of a nil image.", self];
    }
    
    CFTimeInterval startTime = CFAbsoluteTimeGetCurrent();
    @MTI_DEFER {
        [self.context recordPerformanceCounter:@"rendergraph.resolution.count" increment:1];
        [self.context recordPerformanceDuration:@"rendergraph.resolution.duration" duration:(CFAbsoluteTimeGetCurrent() - startTime)];
    };
    id<MTIImagePromise> promise = image.promise;
    
    MTIImagePromiseRenderTarget *renderTarget = nil;
    if (_resolvedPromises.count(promise) > 0) {
        renderTarget = _resolvedPromises.at(promise);
        //Do not need to retain the render target, because it is created or retained during in this rendering context from location [A] or [B].
        //Promise resolved.
        NSAssert(renderTarget != nil, @"");
        NSAssert(renderTarget.texture != nil, @"");
    } else {
        //Maybe the context has a resolved promise. (The image has a persistent cache policy)
        renderTarget = [self.context renderTargetForPromise:promise];
        if ([renderTarget retainTexture]) {
            //Got the render target from the context, we need to retain the texture here, texture ref-count +1. [A]
            //If we don't retain the texture, there will be an over-release error at location [C].
            //The cached render target is valid.
            NSAssert(renderTarget != nil, @"");
            NSAssert(renderTarget.texture != nil, @"");
        } else {
            //All caches miss. Resolve promise.
            NSError *error = nil;
            
            if (promise.dimensions.width > 0 && promise.dimensions.height > 0 && promise.dimensions.depth > 0) {
                
                NSArray<MTIImage *> *dependencies = promise.dependencies;
                NSUInteger dependencyCount = dependencies.count;
                
                std::vector<MTIImagePromiseRenderTarget *> inputRenderTargets(dependencyCount, nil);
                
                std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLTexture>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> textureMap;
                textureMap.reserve(dependencyCount);
                
                std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLSamplerState>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> samplerStateMap;
                samplerStateMap.reserve(dependencyCount);
                
                CFTimeInterval dependencyResolutionStartTime = CFAbsoluteTimeGetCurrent();
                for (NSUInteger index = 0; index < dependencyCount; index += 1) {
                    MTIImage *dependencyImage = dependencies[index];
                    MTIImagePromiseRenderTarget *inputRenderTarget = nil;
                    auto iterator = _resolvedPromises.find(dependencyImage.promise);
                    if (iterator != _resolvedPromises.end()) {
                        inputRenderTarget = iterator->second;
                    } else {
                        inputRenderTarget = [self resolvePreparedRenderTargetForImage:dependencyImage error:&error];
                    }
                    if (error) {
                        break;
                    }
                    NSAssert(inputRenderTarget != nil, @"");
                    inputRenderTargets[index] = inputRenderTarget;
                    textureMap[dependencyImage] = inputRenderTarget.texture;
                    
                    id<MTLSamplerState> samplerState = [self samplerStateForImage:dependencyImage error:&error];
                    if (error) {
                        break;
                    }
                    NSAssert(samplerState != nil, @"");
                    samplerStateMap[dependencyImage] = samplerState;
                }
                [self.context recordPerformanceDuration:@"rendergraph.dependencyResolution.duration" duration:(CFAbsoluteTimeGetCurrent() - dependencyResolutionStartTime)];
                
                if (!error) {
                    auto previousResolutionMap = std::move(_currentDependencyResolutionMap);
                    auto previousSamplerStateMap = std::move(_currentDependencySamplerStateMap);
                    auto previousResolvingPromise = _currentResolvingPromise;
                    _currentDependencyResolutionMap = std::move(textureMap);
                    _currentDependencySamplerStateMap = std::move(samplerStateMap);
                    _currentResolvingPromise = promise;
                    @MTI_DEFER {
                        self -> _currentDependencyResolutionMap = std::move(previousResolutionMap);
                        self -> _currentDependencySamplerStateMap = std::move(previousSamplerStateMap);
                        self -> _currentResolvingPromise = previousResolvingPromise;
                    };
                    CFTimeInterval promiseResolveStartTime = CFAbsoluteTimeGetCurrent();
                    renderTarget = [promise resolveWithContext:self error:&error];
                    [self.context recordPerformanceCounter:@"rendergraph.promiseResolve.count" increment:1];
                    [self.context recordPerformanceDuration:@"rendergraph.promiseResolve.duration" duration:(CFAbsoluteTimeGetCurrent() - promiseResolveStartTime)];
                    //New render target got from promise resolving, texture ref-count is 1. [B]
                }
                
                CFTimeInterval dependencyConsumptionStartTime = CFAbsoluteTimeGetCurrent();
                for (NSUInteger index = 0; index < dependencyCount; index += 1) {
                    MTIImagePromiseRenderTarget *inputRenderTarget = inputRenderTargets[index];
                    if (inputRenderTarget) {
                        [self consumeRenderTarget:inputRenderTarget forPromise:dependencies[index].promise consumer:promise];
                    }
                }
                [self.context recordPerformanceDuration:@"rendergraph.dependencyConsumption.duration" duration:(CFAbsoluteTimeGetCurrent() - dependencyConsumptionStartTime)];
            } else {
                error = MTIErrorCreate(MTIErrorInvalidTextureDimension, nil);
            }
            
                if (error) {
                    if (inOutError) {
                        *inOutError = error;
                    }
                
                    //Failed. Release texture if we got the render target.
                    [renderTarget releaseTexture];
                    
                    return nil;
                }
            
            //Make sure the render target is valid.
            NSAssert(renderTarget != nil, @"");
            NSAssert(renderTarget.texture != nil, @"");
            
            if (image.cachePolicy == MTIImageCachePolicyPersistent) {
                //Share the render result with the context.
                [self.context setRenderTarget:renderTarget forPromise:promise];
            }
        }
        _resolvedPromises[promise] = renderTarget;
    }
    
    if (image.cachePolicy == MTIImageCachePolicyPersistent) {
        MTIPersistImageResolutionHolder *persistResolution = [self.context valueForImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
        if (!persistResolution) {
            //Create a holder for the render taget. Retain the texture. Preventing the texture from being reused at location [C]
            //When the MTIPersistImageResolutionHolder deallocates, it releases the texture.
            persistResolution = [[MTIPersistImageResolutionHolder alloc] initWithRenderTarget:renderTarget];
            [self.context setValue:persistResolution forImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
        }
    }
    
    return renderTarget;
}

- (id<MTIImagePromiseResolution>)resolutionForImage:(MTIImage *)image error:(NSError * __autoreleasing *)inOutError {
    BOOL isRootImage = (_dependencyGraph == NULL);
    MTIImagePromiseRenderTarget *renderTarget = [self resolveRenderTargetForImage:image error:inOutError];
    if (!renderTarget) {
        return nil;
    }
    
    if (isRootImage) {
        return [[MTITransientImagePromiseResolution alloc] initWithTexture:renderTarget.texture invalidationHandler:^(id consumer) {
            //Root render result is consumed, releasing the texture.
            [renderTarget releaseTexture];
        }];
    } else {
        return [[MTITransientImagePromiseResolution alloc] initWithTexture:renderTarget.texture invalidationHandler:^(id consumer){
            [self consumeRenderTarget:renderTarget forPromise:image.promise consumer:consumer];
        }];
    }
}

@end


__attribute__((objc_subclassing_restricted))
@interface MTIImageBufferPromise: NSObject <MTIImagePromise>

@property (nonatomic, strong, readonly) MTIPersistImageResolutionHolder *resolution;

@property (nonatomic, weak, readonly) MTIContext *context;

@end

@implementation MTIImageBufferPromise

@synthesize dimensions = _dimensions;
@synthesize alphaType = _alphaType;

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (NSArray<MTIImage *> *)dependencies {
    return @[];
}

- (instancetype)initWithPersistImageResolutionHolder:(MTIPersistImageResolutionHolder *)holder dimensions:(MTITextureDimensions)dimensions alphaType:(MTIAlphaType)alphaType context:(MTIContext *)context {
    if (self = [super init]) {
        _dimensions = dimensions;
        _alphaType = alphaType;
        _resolution = holder;
        _context = context;
    }
    return self;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError * __autoreleasing *)error {
    MTIContext *context = self.context;
    NSParameterAssert(renderingContext.context == context);
    if (renderingContext.context != context) {
        if (error) {
            *error = MTIErrorCreate(MTIErrorCrossContextRendering, nil);
        }
        return nil;
    }
    [_resolution.renderTarget retainTexture];
    return _resolution.renderTarget;
}


- (instancetype)promiseByUpdatingDependencies:(NSArray<MTIImage *> *)dependencies {
    NSParameterAssert(dependencies.count == 0);
    return self;
}

- (MTIImagePromiseDebugInfo *)debugInfo {
    return [[MTIImagePromiseDebugInfo alloc] initWithPromise:self type:MTIImagePromiseTypeSource content:self.resolution];
}

@end


@implementation MTIContext (RenderedImageBuffer)

- (MTIImage *)renderedBufferForImage:(MTIImage *)targetImage {
    NSParameterAssert(targetImage.cachePolicy == MTIImageCachePolicyPersistent);
    MTIPersistImageResolutionHolder *persistResolution = [self valueForImage:targetImage inTable:MTIContextImagePersistentResolutionHolderTable];
    if (!persistResolution) {
        return nil;
    }
    return [[MTIImage alloc] initWithPromise:[[MTIImageBufferPromise alloc] initWithPersistImageResolutionHolder:persistResolution dimensions:targetImage.dimensions alphaType:targetImage.alphaType context:self] samplerDescriptor:targetImage.samplerDescriptor cachePolicy:MTIImageCachePolicyPersistent];
}

@end

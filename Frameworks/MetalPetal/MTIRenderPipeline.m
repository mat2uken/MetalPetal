//
//  MTIRenderPipelineInfo.m
//  Pods
//
//  Created by YuAo on 30/06/2017.
//
//

#import "MTIRenderPipeline.h"

@interface MTIRenderPipeline ()

@property (nonatomic, strong, readwrite) NSArray<MTLArgument *> *vertexTextureArguments;
@property (nonatomic, strong, readwrite) NSArray<MTLArgument *> *fragmentTextureArguments;
@property (nonatomic, strong, readwrite) NSArray<MTLArgument *> *vertexBufferArguments;
@property (nonatomic, strong, readwrite) NSArray<MTLArgument *> *fragmentBufferArguments;

@end

static NSArray<MTLArgument *> * MTIRenderPipelineArgumentsMatchingType(NSArray<MTLArgument *> *arguments, MTLArgumentType type) {
    NSMutableArray<MTLArgument *> *matchedArguments = [NSMutableArray array];
    for (MTLArgument *argument in arguments) {
        if (argument.type == type) {
            [matchedArguments addObject:argument];
        }
    }
    return [matchedArguments copy];
}

@implementation MTIRenderPipeline

- (instancetype)initWithState:(id<MTLRenderPipelineState>)state reflection:(MTLRenderPipelineReflection *)reflection {
    if (self = [super init]) {
        _state = state;
        _reflection = reflection;
        _vertexTextureArguments = MTIRenderPipelineArgumentsMatchingType(reflection.vertexArguments, MTLArgumentTypeTexture);
        _fragmentTextureArguments = MTIRenderPipelineArgumentsMatchingType(reflection.fragmentArguments, MTLArgumentTypeTexture);
        _vertexBufferArguments = MTIRenderPipelineArgumentsMatchingType(reflection.vertexArguments, MTLArgumentTypeBuffer);
        _fragmentBufferArguments = MTIRenderPipelineArgumentsMatchingType(reflection.fragmentArguments, MTLArgumentTypeBuffer);
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

@end

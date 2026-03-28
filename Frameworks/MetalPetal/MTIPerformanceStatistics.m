//
//  MTIPerformanceStatistics.m
//  MetalPetal
//

#import "MTIPerformanceStatistics.h"

@implementation MTIPerformanceStatisticsSnapshot

- (instancetype)initWithCounters:(NSDictionary<NSString *,NSNumber *> *)counters
                       durations:(NSDictionary<NSString *,NSNumber *> *)durations {
    if (self = [super init]) {
        _counters = [counters copy];
        _durations = [durations copy];
    }
    return self;
}

- (NSNumber *)counterNamed:(NSString *)name {
    return self.counters[name];
}

- (NSNumber *)durationNamed:(NSString *)name {
    return self.durations[name];
}

@end

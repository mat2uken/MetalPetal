//
//  MTIPerformanceStatistics.h
//  MetalPetal
//

#import <Foundation/Foundation.h>
#if __has_include(<MetalPetal/MTIContext.h>)
#import <MetalPetal/MTIContext.h>
#else
#import "MTIContext.h"
#endif

NS_ASSUME_NONNULL_BEGIN

/// An immutable snapshot of collected performance counters and durations.
__attribute__((objc_subclassing_restricted))
@interface MTIPerformanceStatisticsSnapshot : NSObject

- (instancetype)init NS_UNAVAILABLE;

+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithCounters:(NSDictionary<NSString *, NSNumber *> *)counters
                       durations:(NSDictionary<NSString *, NSNumber *> *)durations NS_DESIGNATED_INITIALIZER;

/// Aggregated counters.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *counters;

/// Aggregated durations in seconds.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *durations;

- (nullable NSNumber *)counterNamed:(NSString *)name;

- (nullable NSNumber *)durationNamed:(NSString *)name;

@end

@interface MTIContext (PerformanceStatistics)

/// Whether performance statistics collection is enabled for this context.
@property (nonatomic, readonly, getter=isPerformanceStatisticsEnabled) BOOL performanceStatisticsEnabled;

/// Clears all collected counters and durations.
- (void)resetPerformanceStatistics;

/// Returns an immutable snapshot of currently collected counters and durations.
- (MTIPerformanceStatisticsSnapshot *)performanceStatisticsSnapshot;

@end

NS_ASSUME_NONNULL_END

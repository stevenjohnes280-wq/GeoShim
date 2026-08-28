// GSConfig.h - immutable snapshot of the preferences plist.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

typedef NS_ENUM(NSInteger, GSMode) {
    GSModeStatic = 0,
    GSModeRoute,
};

// How -[CLLocation sourceInformation] should read on a spoofed fix.
//   Nil         - build through the public initializer; the property is nil,
//                 which is what a CLLocation built by anyone else looks like.
//   Clean       - attach a CLLocationSourceInformation with both flags NO.
//   Passthrough - copy whatever the real fix reported, if we have seen one.
typedef NS_ENUM(NSInteger, GSRouteEnd) {
    GSRouteEndLoop = 0,
    GSRouteEndReverse,
    GSRouteEndStop,
};

typedef NS_ENUM(NSInteger, GSSourceInfoMode) {
    GSSourceInfoModeNil = 0,
    GSSourceInfoModeClean,
    GSSourceInfoModePassthrough,
};

@interface GSConfig : NSObject

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, readonly) CLLocationDistance altitude;
@property (nonatomic, readonly) GSMode mode;
@property (nonatomic, readonly) GSSourceInfoMode sourceInfoMode;
@property (nonatomic, readonly) double jitterMetres;
@property (nonatomic, readonly) NSTimeInterval updateInterval;
@property (nonatomic, readonly, copy) NSString *routePath;
@property (nonatomic, readonly) BOOL routeLoop;
@property (nonatomic, readonly) GSRouteEnd routeEndBehavior;
@property (nonatomic, readonly) double routeSpeedMps;

// Deliver spoofed callbacks on a timer even when the real subsystem is silent.
@property (nonatomic, readonly) BOOL synthesizeUpdates;

// Debug builds only: log the sourceInformation of genuine fixes (section 4.1
// of the brief) at most once every few seconds.
@property (nonatomic, readonly) BOOL logRealFixes;

// Bumped on every reload so stateful consumers (the route engine) can reset.
@property (nonatomic, readonly) uint64_t generation;

// Latest snapshot. Cheap; safe to call from any thread and any hook.
+ (instancetype)current;

// Re-read the plist. Called from the Darwin notification callback.
+ (void)reload;

@end

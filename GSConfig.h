// GSConfig.h - immutable snapshot of the preferences plist. Static spoofing only.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// How -[CLLocation sourceInformation] should read on a spoofed fix.
//   Nil         - build through the public initializer; the property is nil,
//                 which is what a CLLocation built by anyone else looks like.
//   Clean       - attach a CLLocationSourceInformation with both flags NO.
//   Passthrough - copy whatever the real fix reported, if we have seen one.
typedef NS_ENUM(NSInteger, GSSourceInfoMode) {
    GSSourceInfoModeNil = 0,
    GSSourceInfoModeClean,
    GSSourceInfoModePassthrough,
};

@interface GSConfig : NSObject

@property (nonatomic, readonly) BOOL enabled;

// Master switch for the in-process (app-side) CoreLocation hooks. On by default:
// the app-side fallback covers every app unless it is excluded below. A load-time
// gate read in the tweak's constructor inside each app - the daemon (locationd)
// path ignores it. Toggling it takes effect on an app's next launch, since
// installed hooks cannot be cleanly removed. `geoshim fallback on|off`.
@property (nonatomic, readonly) BOOL appFallback;

// Bundle identifiers the app-side fallback is switched OFF for, chosen in Settings
// via the AltList picker (the DisabledBundles array). The fallback is normally-on,
// so this is an exclusion list: an empty list means every app is covered. The
// daemon path is unaffected and always spoofs every client.
@property (nonatomic, readonly, copy) NSArray<NSString *> *disabledBundles;

@property (nonatomic, readonly) CLLocationCoordinate2D coordinate;
@property (nonatomic, readonly) CLLocationDistance altitude;
@property (nonatomic, readonly) GSSourceInfoMode sourceInfoMode;
@property (nonatomic, readonly) double jitterMetres;
@property (nonatomic, readonly) NSTimeInterval updateInterval;

// Deliver spoofed callbacks on a timer even when the real subsystem is silent.
@property (nonatomic, readonly) BOOL synthesizeUpdates;

// Debug builds only: log the sourceInformation of genuine fixes at most once
// every few seconds.
@property (nonatomic, readonly) BOOL logRealFixes;

// Bumped on every reload so stateful consumers can reset.
@property (nonatomic, readonly) uint64_t generation;

// YES when the app-side fallback should install in a process with this bundle id:
// the master switch is on AND the bundle is not in the exclusion list.
- (BOOL)appFallbackEnabledForBundle:(NSString *)bundleIdentifier;

// Latest snapshot. Cheap; safe to call from any thread and any hook.
+ (instancetype)current;

// Re-read the plist. Called from the Darwin notification callback.
+ (void)reload;

@end

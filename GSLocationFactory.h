// GSLocationFactory.h - builds the CLLocation objects we hand to the host app.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface GSLocationFactory : NSObject

+ (instancetype)shared;

// YES when the current config says to substitute locations at all.
- (BOOL)active;

// Builds the next spoofed fix. `real` may be nil; it is only consulted for
// SourceInfoMode == passthrough and for altitude when none is configured.
// Returns nil if spoofing is off or construction failed, in which case the
// caller must pass the real location through unchanged.
- (CLLocation *)spoofedLocationFromReal:(CLLocation *)real;

// Remembers the most recent genuine fix (for passthrough mode, and for the
// section 4.1 probe logging in debug builds).
- (void)noteRealLocation:(CLLocation *)real;

// Which of the sourceInformation attachment strategies was resolved at load.
- (NSString *)sourceInfoStrategyDescription;

@end

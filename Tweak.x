// GeoShim - system-wide location substitution inside locationd.
//
// This tweak injects ONLY into locationd. Positions are handed to every client
// as an NSSecureCoding keyed archive over XPC, so -[CLLocation encodeWithCoder:]
// is the one point where an outbound fix is serialised - and it is reached even
// by a client whose own in-process injection is blacklisted by roothide, which
// is the entire reason for hooking the daemon rather than the app.
//
// Everything here fails open. If any step throws or returns nil, the real
// location is encoded untouched.

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdlib.h>
#import <string.h>

#import "GSCommon.h"
#import "GSConfig.h"
#import "GSLocationFactory.h"
#import "GSRouteEngine.h"

#pragma mark - Daemon hook (locationd)

// We replace the *object* being encoded rather than guessing the archive's key
// names: build a fully spoofed CLLocation and run the original encoder on it.
// Whatever keys CLLocation normally writes, it writes for the spoofed object.
// Done as a manual swizzle (not a %hook) so we can invoke the original IMP
// against a different target.
static IMP gEncodeWithCoderOrig = NULL;

static void gs_encodeWithCoder(id self, SEL _cmd, NSCoder *coder) {
    @try {
        GSLocationFactory *factory = [GSLocationFactory shared];
        if (factory.active && [self isKindOfClass:[CLLocation class]]) {
            CLLocation *real = (CLLocation *)self;

            // Only rewrite plausible position fixes. Region/visit archiving and
            // other internal round-trips of a CLLocation with an invalid
            // coordinate are left alone.
            if (CLLocationCoordinate2DIsValid(real.coordinate)) {
                [factory noteRealLocation:real];
                CLLocation *fake = [factory spoofedLocationFromReal:real];
                if (fake && gEncodeWithCoderOrig) {
                    if (GEOSHIM_DEBUG_BUILD) {
                        GSLog(@"locationd: encode %f,%f -> %f,%f",
                              real.coordinate.latitude, real.coordinate.longitude,
                              fake.coordinate.latitude, fake.coordinate.longitude);
                    }
                    ((void (*)(id, SEL, NSCoder *))gEncodeWithCoderOrig)(fake, _cmd, coder);
                    return;
                }
            }
        }
    } @catch (NSException *e) {
        GSLog(@"locationd: encodeWithCoder substitution failed: %@", e);
    }

    if (gEncodeWithCoderOrig) {
        ((void (*)(id, SEL, NSCoder *))gEncodeWithCoderOrig)(self, _cmd, coder);
    }
}

static void gs_installDaemonHook(void) {
    SEL sel = @selector(encodeWithCoder:);
    Method m = class_getInstanceMethod([CLLocation class], sel);
    if (!m) {
        GSLog(@"locationd: CLLocation has no encodeWithCoder:; daemon hook not installed");
        return;
    }
    gEncodeWithCoderOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)gs_encodeWithCoder);
    GSLog(@"locationd: encodeWithCoder: hook installed");
}

#pragma mark - Process guard

// The filter targets only the locationd executable, but guard anyway so that a
// widened filter can never install this hook into an ordinary app.
static BOOL gs_isLocationd(void) {
    const char *name = getprogname();
    return name && strcmp(name, "locationd") == 0;
}

#pragma mark - Preferences reload

static void gs_prefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    @try {
        [GSConfig reload];
        [[GSRouteEngine shared] reset];
    } @catch (NSException *e) {
        GSLog(@"prefs: reload threw %@", e);
    }
}

%ctor {
    @autoreleasepool {
        if (!gs_isLocationd()) {
            // Not the daemon: do nothing at all, install nothing. The filter
            // should prevent us ever loading elsewhere, but if it does, this
            // process is left byte-for-byte as if the tweak were absent.
            return;
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, gs_prefsChanged,
                                        CFSTR(GS_NOTIFY_NAME),
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);

        gs_installDaemonHook();

        GSConfig *config = [GSConfig current];
        GSLog(@"loaded in locationd (enabled=%d mode=%ld srcinfo=%ld strategy=%@)",
              config.enabled, (long)config.mode, (long)config.sourceInfoMode,
              [[GSLocationFactory shared] sourceInfoStrategyDescription]);
    }
}

// GeoShim Settings page. The app picker is AltList's
// ATLApplicationListMultiSelectionController, driven from Root.plist (the same
// framework Choicy and Shadow use). Alongside it this controller shows a live
// status readout (state / coordinate / a locationd assertion) and pushes
// GeoShimMapController for setting the coordinate on a map.
//
// The status rows refresh three ways so the locationd line never gets stuck:
// on page-appear, on the prefsChanged Darwin notification (so toggling spoofing
// updates it at once), and on a 2 s poll while the page is visible. The locationd
// ping runs off the main thread so the UI never blocks.

#import "GeoShimRootListController.h"
#import "GeoShimMapController.h"
#import "GSCommon.h"
#import <notify.h>

static NSString *const kGSDomain = @"xyz.regulad.geoshim";

@implementation GeoShimRootListController {
    NSString *_locationdStatus;
    NSTimer *_pollTimer;
    BOOL _observing;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

static void gs_settingsPrefsChanged(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    GeoShimRootListController *ctrl = (__bridge GeoShimRootListController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [ctrl refreshStatus]; });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!_observing) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        gs_settingsPrefsChanged,
                                        CFSTR(GS_NOTIFY_NAME),
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
        _observing = YES;
    }
    [_pollTimer invalidate];
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:self
                                                selector:@selector(refreshStatus)
                                                userInfo:nil
                                                 repeats:YES];
    [self refreshStatus];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
    if (_observing) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           (__bridge const void *)self,
                                           CFSTR(GS_NOTIFY_NAME), NULL);
        _observing = NO;
    }
}

- (void)dealloc {
    [_pollTimer invalidate];
    if (_observing) {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           (__bridge const void *)self,
                                           CFSTR(GS_NOTIFY_NAME), NULL);
    }
}

- (id)gs_read:(NSString *)key {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kGSDomain);
    return v ? (__bridge_transfer id)v : nil;
}

// Ping the tweak inside locationd and wait briefly for it to answer. Mirrors the
// CLI's pingDaemon; the shared fingerprint lives in GSCommon.h so both sides
// agree. Runs off the main thread (see refreshStatus).
- (BOOL)gs_pingDaemon:(uint64_t *)stateOut timeout:(double)timeoutSec {
    int token = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    uint32_t r = notify_register_dispatch(GS_NOTIFY_STATUS_REPLY, &token,
                                          dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
                                          ^(int t) { (void)t; dispatch_semaphore_signal(sem); });
    if (r != NOTIFY_STATUS_OK) return NO;
    notify_post(GS_NOTIFY_STATUS_REQ);
    long timedOut = dispatch_semaphore_wait(sem,
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC)));
    BOOL responded = (timedOut == 0);
    if (responded && stateOut) {
        uint64_t s = 0;
        notify_get_state(token, &s);
        *stateOut = s;
    }
    notify_cancel(token);
    return responded;
}

- (NSString *)computeLocationdStatus {
    uint64_t st = 0;
    if (![self gs_pingDaemon:&st timeout:0.5]) return @"not responding";
    if (!(st & GS_STATUS_ENABLED)) return @"live (disabled)";
    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if (![la isKindOfClass:[NSNumber class]] || ![lo isKindOfClass:[NSNumber class]]) return @"live";
    uint32_t expected = gs_coord_fingerprint([la doubleValue], [lo doubleValue]);
    uint32_t reported = (uint32_t)((st >> GS_STATUS_FP_SHIFT) & GS_STATUS_FP_MASK);
    return (reported == expected) ? @"serving this coordinate" : @"value differs";
}

// Reload the read-only status rows: State/Coordinate immediately (cheap CFPrefs
// reads) and the locationd line via an async ping so the main thread never blocks.
- (void)refreshStatus {
    PSSpecifier *stateSpec = [self specifierForID:@"statusState"];
    if (stateSpec) [self reloadSpecifier:stateSpec animated:NO];
    PSSpecifier *coordSpec = [self specifierForID:@"statusCoordinate"];
    if (coordSpec) [self reloadSpecifier:coordSpec animated:NO];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *status = [self computeLocationdStatus];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![status isEqualToString:self->_locationdStatus]) {
                self->_locationdStatus = status;
                PSSpecifier *spec = [self specifierForID:@"statusLocationd"];
                if (spec) [self reloadSpecifier:spec animated:NO];
            }
        });
    });
}

#pragma mark - Status readout (Root.plist `get` selectors)

- (id)statusState:(PSSpecifier *)specifier {
    return [[self gs_read:@"Enabled"] boolValue] ? @"Enabled" : @"Disabled";
}

- (id)statusCoordinate:(PSSpecifier *)specifier {
    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if (![la isKindOfClass:[NSNumber class]] || ![lo isKindOfClass:[NSNumber class]]) return @"—";
    return [NSString stringWithFormat:@"%.5f, %.5f", [la doubleValue], [lo doubleValue]];
}

- (id)statusLocationd:(PSSpecifier *)specifier {
    return _locationdStatus ?: @"checking…";
}

#pragma mark - Map picker (Root.plist `action`)

- (void)openMap {
    GeoShimMapController *map = [[GeoShimMapController alloc] init];
    [self.navigationController pushViewController:map animated:YES];
}

@end

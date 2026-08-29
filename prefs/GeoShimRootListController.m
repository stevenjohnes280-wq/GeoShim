// GeoShim Settings page. The app picker is AltList's
// ATLApplicationListMultiSelectionController, driven from Root.plist (the same
// framework Choicy and Shadow use). Alongside it this controller shows a live,
// polled status readout and pushes GeoShimMapController for the map picker.
//
// The status is read from locationd itself, not the plist, so it never lies the
// way the Enabled switch (a write-only input) can. Two rows come straight from a
// daemon ping - "Hook State" (is the tweak loaded/responding in locationd) and
// "Spoofing State" (is spoofing actually on, and serving the configured
// coordinate). Both refresh on page-appear, on the prefsChanged notification,
// and on a 2 s poll. The ping runs off the main thread so the UI never blocks.

#import "GeoShimRootListController.h"
#import "GeoShimMapController.h"
#import "GSCommon.h"
#import <notify.h>

static NSString *const kGSDomain = @"xyz.regulad.geoshim";

@implementation GeoShimRootListController {
    NSString *_hookState;
    NSString *_spoofState;
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
    dispatch_async(dispatch_get_main_queue(), ^{ [ctrl onExternalChange]; });
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

// Ping the tweak inside locationd and wait briefly for a reply. Mirrors the CLI's
// pingDaemon; the shared fingerprint lives in GSCommon.h so both sides agree.
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

- (NSString *)hookStateFromPing:(BOOL)alive state:(uint64_t)st {
    if (!alive) return @"not loaded";
    if (!(st & GS_STATUS_CL_HOOK)) return @"loaded, CLLocation hook MISSING";
    if (!(st & GS_STATUS_VISIT_HOOK)) return @"loaded (no visit hook)";
    return @"loaded";
}

- (NSString *)spoofStateFromPing:(BOOL)alive state:(uint64_t)st {
    if (!alive) return @"unknown (daemon not responding)";
    if (!(st & GS_STATUS_ENABLED)) return @"off";
    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if ([la isKindOfClass:[NSNumber class]] && [lo isKindOfClass:[NSNumber class]]) {
        uint32_t expected = gs_coord_fingerprint([la doubleValue], [lo doubleValue]);
        uint32_t reported = (uint32_t)((st >> GS_STATUS_FP_SHIFT) & GS_STATUS_FP_MASK);
        if (reported != expected) return @"on (daemon coordinate differs)";
    }
    return @"on";
}

// Coordinate is a cheap plist read; Hook/Spoofing come from one async daemon ping
// so the main thread never blocks. Only rows whose text actually changed reload.
- (void)refreshStatus {
    PSSpecifier *coordSpec = [self specifierForID:@"statusCoordinate"];
    if (coordSpec) [self reloadSpecifier:coordSpec animated:NO];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint64_t st = 0;
        BOOL alive = [self gs_pingDaemon:&st timeout:0.5];
        NSString *hook = [self hookStateFromPing:alive state:st];
        NSString *spoof = [self spoofStateFromPing:alive state:st];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![hook isEqualToString:self->_hookState]) {
                self->_hookState = hook;
                PSSpecifier *s = [self specifierForID:@"statusHook"];
                if (s) [self reloadSpecifier:s animated:NO];
            }
            if (![spoof isEqualToString:self->_spoofState]) {
                self->_spoofState = spoof;
                PSSpecifier *s = [self specifierForID:@"statusSpoofing"];
                if (s) [self reloadSpecifier:s animated:NO];
            }
        });
    });
}

// The prefsChanged notification also means the Enabled switch may be stale (e.g.
// a `geoshim start/stop` flipped it), so correct the switch too - only here, not
// on the 2 s poll, so it never fights a live toggle.
- (void)onExternalChange {
    PSSpecifier *sw = [self specifierForID:@"enabledSwitch"];
    if (sw) [self reloadSpecifier:sw animated:NO];
    [self refreshStatus];
}

#pragma mark - Status readout (Root.plist `get` selectors)

- (id)statusHook:(PSSpecifier *)specifier {
    return _hookState ?: @"checking…";
}

- (id)statusSpoofing:(PSSpecifier *)specifier {
    return _spoofState ?: @"checking…";
}

- (id)statusCoordinate:(PSSpecifier *)specifier {
    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if (![la isKindOfClass:[NSNumber class]] || ![lo isKindOfClass:[NSNumber class]]) return @"—";
    return [NSString stringWithFormat:@"%.5f, %.5f", [la doubleValue], [lo doubleValue]];
}

#pragma mark - Enabled switch (real toggle, not just a plist write)

- (id)getEnabled:(PSSpecifier *)specifier {
    return @([[self gs_read:@"Enabled"] boolValue]);
}

// A plain PSSwitchCell only writes the pref through cfprefsd, whose flush to disk
// can land after the PostNotification - so the daemon reloads the OLD value and
// never bounces, and the switch "does nothing". Instead we synchronize the value
// to disk first, then post prefsChanged: the daemon reads the new value, applies
// it, and SIGKILLs itself to re-grab (its self-restart fires on the enabled
// change). This mirrors what the map picker and the `geoshim` CLI already do.
- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    BOOL on = [value boolValue];
    CFPreferencesSetAppValue(CFSTR("Enabled"),
                             on ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)kGSDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kGSDomain);
    notify_post(GS_NOTIFY_NAME);
    [self refreshStatus];
}

#pragma mark - Map picker (Root.plist `action`)

- (void)openMap {
    GeoShimMapController *map = [[GeoShimMapController alloc] init];
    [self.navigationController pushViewController:map animated:YES];
}

@end

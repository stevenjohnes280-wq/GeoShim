// GeoShim Settings page. The app picker is AltList's
// ATLApplicationListMultiSelectionController, driven from Root.plist (the same
// framework Choicy and Shadow use). Alongside it this controller shows a live
// status readout (state / coordinate / a locationd assertion) via the get:
// selectors below, and pushes GeoShimMapController for setting the coordinate on
// a map. The switches and the picker persist through cfprefsd to the
// xyz.regulad.geoshim domain - the same plist the tweak and CLI read.

#import "GeoShimRootListController.h"
#import "GeoShimMapController.h"
#import "GSCommon.h"
#import <notify.h>

static NSString *const kGSDomain = @"xyz.regulad.geoshim";

@implementation GeoShimRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Refresh the read-only status rows whenever the page reappears (e.g. after
// returning from the map, or after a `geoshim` command changed the plist).
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (id)gs_read:(NSString *)key {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kGSDomain);
    return v ? (__bridge_transfer id)v : nil;
}

// Ping the tweak inside locationd and wait briefly for it to answer. Mirrors the
// CLI's pingDaemon; the shared fingerprint lives in GSCommon.h so both sides
// agree. A short timeout keeps the (main-thread) status refresh snappy.
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

// Actually contacts locationd and asserts it is serving the configured value.
- (id)statusLocationd:(PSSpecifier *)specifier {
    uint64_t st = 0;
    if (![self gs_pingDaemon:&st timeout:0.5]) return @"not responding";
    if (!(st & GS_STATUS_ENABLED)) return @"live (disabled)";

    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if (![la isKindOfClass:[NSNumber class]] || ![lo isKindOfClass:[NSNumber class]]) return @"live";
    uint32_t expected = gs_coord_fingerprint([la doubleValue], [lo doubleValue]);
    uint32_t reported = (uint32_t)((st >> GS_STATUS_FP_SHIFT) & GS_STATUS_FP_MASK);
    return (reported == expected) ? @"serving this coordinate ✓" : @"value differs";
}

#pragma mark - Map picker (Root.plist `action`)

- (void)openMap {
    GeoShimMapController *map = [[GeoShimMapController alloc] init];
    [self.navigationController pushViewController:map animated:YES];
}

@end

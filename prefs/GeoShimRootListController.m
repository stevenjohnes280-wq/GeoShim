// GeoShim Settings page. The app picker is AltList's
// ATLApplicationListMultiSelectionController, driven from Root.plist (the same
// framework Choicy and Shadow use). Alongside it this controller shows a live
// status readout (state / coordinate / mode) via the get: selectors below, and
// pushes GeoShimMapController for setting the coordinate on a map. Both the
// picker and the Enabled/AppFallback switches persist through cfprefsd to the
// xyz.regulad.geoshim domain - the same plist the tweak and CLI read.

#import "GeoShimRootListController.h"
#import "GeoShimMapController.h"

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

- (id)statusMode:(PSSpecifier *)specifier {
    return [[self gs_read:@"Mode"] isEqual:@"route"] ? @"Route" : @"Static";
}

#pragma mark - Map picker (Root.plist `action`)

- (void)openMap {
    GeoShimMapController *map = [[GeoShimMapController alloc] init];
    [self.navigationController pushViewController:map animated:YES];
}

@end

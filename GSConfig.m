#import "GSConfig.h"
#import "GSCommon.h"
#import <os/lock.h>

@interface GSConfig ()
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, readwrite) BOOL appFallback;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *disabledBundles;
@property (nonatomic, readwrite) CLLocationCoordinate2D coordinate;
@property (nonatomic, readwrite) CLLocationDistance altitude;
@property (nonatomic, readwrite) GSSourceInfoMode sourceInfoMode;
@property (nonatomic, readwrite) double jitterMetres;
@property (nonatomic, readwrite) NSTimeInterval updateInterval;
@property (nonatomic, readwrite) BOOL synthesizeUpdates;
@property (nonatomic, readwrite) BOOL logRealFixes;
@property (nonatomic, readwrite) uint64_t generation;
@end

static os_unfair_lock gGSConfigLock = OS_UNFAIR_LOCK_INIT;
static GSConfig *gGSCurrent = nil;
static uint64_t gGSGeneration = 0;

static double gs_number(NSDictionary *d, NSString *key, double fallback) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

static BOOL gs_bool(NSDictionary *d, NSString *key, BOOL fallback) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}

static NSString *gs_string(NSDictionary *d, NSString *key, NSString *fallback) {
    id v = d[key];
    return [v isKindOfClass:[NSString class]] ? v : fallback;
}

@implementation GSConfig

// A config that spoofs nothing. Every parse failure lands here, so a missing,
// truncated or unreadable plist fails open: the host app sees real locations.
+ (instancetype)disabledConfig {
    GSConfig *c = [[GSConfig alloc] init];
    c.enabled = NO;
    // Default ON: the app-side gate is on even when the plist is missing or
    // unreadable, so the fallback hooks still install (they stay inert while
    // Enabled is NO). Only an explicit AppFallback=false turns them off.
    c.appFallback = YES;
    c.disabledBundles = @[];
    c.coordinate = kCLLocationCoordinate2DInvalid;
    c.altitude = 0.0;
    c.sourceInfoMode = GSSourceInfoModeNil;
    c.jitterMetres = 2.0;
    c.updateInterval = 1.0;
    c.synthesizeUpdates = YES;
    c.logRealFixes = NO;
    c.generation = gGSGeneration;
    return c;
}

+ (instancetype)configFromDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return [self disabledConfig];

    GSConfig *c = [self disabledConfig];
    c.enabled = gs_bool(d, @"Enabled", NO);
    c.appFallback = gs_bool(d, @"AppFallback", YES);

    // DisabledBundles: the AltList picker writes an array of bundle-id strings
    // (the apps the normally-on fallback is switched OFF for). Filter to strings
    // so a malformed plist cannot inject non-strings.
    id bundles = d[@"DisabledBundles"];
    if ([bundles isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (id b in bundles) {
            if ([b isKindOfClass:[NSString class]] && [(NSString *)b length]) [clean addObject:b];
        }
        c.disabledBundles = clean;
    }

    double lat = gs_number(d, @"Latitude", 0.0);
    double lon = gs_number(d, @"Longitude", 0.0);
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lon);
    if (!CLLocationCoordinate2DIsValid(coord)) {
        GSLog(@"config: coordinate %f,%f is out of range; refusing to spoof", lat, lon);
        return [self disabledConfig];
    }
    c.coordinate = coord;
    c.altitude = gs_number(d, @"Altitude", 0.0);

    NSString *sim = gs_string(d, @"SourceInfoMode", @"nil");
    if ([sim isEqualToString:@"clean"]) {
        c.sourceInfoMode = GSSourceInfoModeClean;
    } else if ([sim isEqualToString:@"passthrough"]) {
        c.sourceInfoMode = GSSourceInfoModePassthrough;
    } else {
        c.sourceInfoMode = GSSourceInfoModeNil;
    }

    c.jitterMetres = fmax(0.0, fmin(50.0, gs_number(d, @"JitterMetres", 2.0)));
    c.updateInterval = fmax(0.1, fmin(60.0, gs_number(d, @"UpdateIntervalSec", 1.0)));
    c.synthesizeUpdates = gs_bool(d, @"SynthesizeUpdates", YES);
    c.logRealFixes = gs_bool(d, @"LogRealFixes", NO);

    c.generation = gGSGeneration;
    return c;
}

- (BOOL)appFallbackEnabledForBundle:(NSString *)bundleIdentifier {
    if (!self.appFallback) return NO;
    if (bundleIdentifier.length == 0) return NO;
    // Normally-on: covered unless explicitly excluded.
    return ![self.disabledBundles containsObject:bundleIdentifier];
}

+ (instancetype)loadFromDisk {
    @try {
        NSString *path = GS_PREFS_PATH;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) {
            // Absent plist is the normal state before first use. An unreadable
            // one usually means the sandbox is blocking the read - see README.
            GSLog(@"config: no readable plist at %@", path);
            return [self disabledConfig];
        }
        return [self configFromDictionary:d];
    } @catch (NSException *e) {
        GSLog(@"config: exception while loading: %@", e);
        return [self disabledConfig];
    }
}

+ (instancetype)current {
    os_unfair_lock_lock(&gGSConfigLock);
    GSConfig *c = gGSCurrent;
    os_unfair_lock_unlock(&gGSConfigLock);
    if (c) return c;

    // First use: load outside the lock, then publish.
    GSConfig *loaded = [self loadFromDisk];
    os_unfair_lock_lock(&gGSConfigLock);
    if (!gGSCurrent) gGSCurrent = loaded;
    c = gGSCurrent;
    os_unfair_lock_unlock(&gGSConfigLock);
    return c;
}

+ (void)reload {
    gGSGeneration++;
    GSConfig *loaded = [self loadFromDisk];
    os_unfair_lock_lock(&gGSConfigLock);
    gGSCurrent = loaded;
    os_unfair_lock_unlock(&gGSConfigLock);
    GSLog(@"config: reloaded gen=%llu enabled=%d coord=%f,%f srcinfo=%ld",
          loaded.generation, loaded.enabled,
          loaded.coordinate.latitude, loaded.coordinate.longitude,
          (long)loaded.sourceInfoMode);
}

@end

// geoshim - writes the preferences plist and pokes the tweak.
//
// All of the logic lives in the dylib. This tool only edits state, posts the
// Darwin notification that makes the change take effect without a respring, and
// (for `status`) pings locationd to confirm the tweak is live and serving the
// configured coordinate. Static spoofing only.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>

#import "GSCommon.h"

static const uid_t kMobileUID = 501;
static const gid_t kMobileGID = 501;

static void usage(void) {
    fprintf(stderr,
        "geoshim - static location substitution control\n"
        "\n"
        "usage:\n"
        "  geoshim start -x <lat> -y <lon> [-a <alt>] [options]\n"
        "  geoshim stop\n"
        "  geoshim fallback <on|off>\n"
        "  geoshim status [--json]\n"
        "\n"
        "fallback toggles the app-side hooks (normally on for every app; the\n"
        "picker in Settings excludes specific apps). The locationd path is always\n"
        "active. status pings locationd to confirm the hook is live and serving\n"
        "the configured coordinate.\n"
        "\n"
        "options:\n"
        "  --source-info <nil|clean|passthrough>  how CLLocation.sourceInformation reads\n"
        "  --jitter <metres>                      per-update coordinate uncertainty (default 2)\n"
        "  --interval <seconds>                   app-side synthetic update cadence (default 1)\n"
        "  --no-synthesize                        only substitute real callbacks (app side)\n"
        "  --debug-log-real                       log genuine fixes (debug builds only)\n"
        "\n"
        "state lives in %s\n",
        GS_PREFS_PATH.UTF8String);
}

static NSMutableDictionary *readPrefs(void) {
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:GS_PREFS_PATH];
    return existing ? [existing mutableCopy] : [NSMutableDictionary dictionary];
}

// The dylib reads this file from inside sandboxed apps running as mobile, so
// a root-owned 0600 plist would be invisible to every one of them.
static BOOL makeReadableByMobile(NSString *path) {
    if (chmod(path.UTF8String, 0644) != 0) return NO;
    if (geteuid() == 0) chown(path.UTF8String, kMobileUID, kMobileGID);
    return YES;
}

static BOOL writePrefs(NSDictionary *prefs) {
    NSString *dir = GS_PREFS_PATH.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        fprintf(stderr, "geoshim: cannot serialise preferences: %s\n",
                error.localizedDescription.UTF8String ?: "unknown error");
        return NO;
    }
    if (![data writeToFile:GS_PREFS_PATH options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "geoshim: cannot write %s: %s\n",
                GS_PREFS_PATH.UTF8String,
                error.localizedDescription.UTF8String ?: "unknown error");
        return NO;
    }
    makeReadableByMobile(GS_PREFS_PATH);
    notify_post(GS_NOTIFY_NAME);
    return YES;
}

static BOOL parseSourceInfo(NSString *value, NSString **out) {
    if ([value isEqualToString:@"nil"] ||
        [value isEqualToString:@"clean"] ||
        [value isEqualToString:@"passthrough"]) {
        *out = value;
        return YES;
    }
    fprintf(stderr, "geoshim: --source-info must be nil, clean or passthrough\n");
    return NO;
}

static int commandStart(NSArray<NSString *> *args) {
    NSMutableDictionary *prefs = readPrefs();
    BOOL haveLat = NO, haveLon = NO;

    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *arg = args[i];
        NSString *next = (i + 1 < args.count) ? args[i + 1] : nil;

        if ([arg isEqualToString:@"-x"] && next) {
            prefs[@"Latitude"] = @(next.doubleValue); haveLat = YES; i++;
        } else if ([arg isEqualToString:@"-y"] && next) {
            prefs[@"Longitude"] = @(next.doubleValue); haveLon = YES; i++;
        } else if ([arg isEqualToString:@"-a"] && next) {
            prefs[@"Altitude"] = @(next.doubleValue); i++;
        } else if ([arg isEqualToString:@"--jitter"] && next) {
            prefs[@"JitterMetres"] = @(next.doubleValue); i++;
        } else if ([arg isEqualToString:@"--interval"] && next) {
            prefs[@"UpdateIntervalSec"] = @(next.doubleValue); i++;
        } else if ([arg isEqualToString:@"--source-info"] && next) {
            NSString *mode = nil;
            if (!parseSourceInfo(next, &mode)) return 1;
            prefs[@"SourceInfoMode"] = mode; i++;
        } else if ([arg isEqualToString:@"--no-synthesize"]) {
            prefs[@"SynthesizeUpdates"] = @NO;
        } else if ([arg isEqualToString:@"--debug-log-real"]) {
            prefs[@"LogRealFixes"] = @YES;
        } else {
            fprintf(stderr, "geoshim: unrecognised argument: %s\n", arg.UTF8String);
            return 1;
        }
    }

    // Re-running start without coordinates resumes the last ones.
    if (!haveLat && !prefs[@"Latitude"]) { fprintf(stderr, "geoshim: -x <lat> is required\n"); return 1; }
    if (!haveLon && !prefs[@"Longitude"]) { fprintf(stderr, "geoshim: -y <lon> is required\n"); return 1; }

    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake([prefs[@"Latitude"] doubleValue],
                                                              [prefs[@"Longitude"] doubleValue]);
    if (!CLLocationCoordinate2DIsValid(coord)) {
        fprintf(stderr, "geoshim: %f,%f is not a valid coordinate\n", coord.latitude, coord.longitude);
        return 1;
    }

    prefs[@"Enabled"] = @YES;
    if (!prefs[@"SourceInfoMode"]) prefs[@"SourceInfoMode"] = @"nil";
    if (!prefs[@"JitterMetres"]) prefs[@"JitterMetres"] = @2.0;
    if (!prefs[@"UpdateIntervalSec"]) prefs[@"UpdateIntervalSec"] = @1.0;

    if (!writePrefs(prefs)) return 1;
    printf("geoshim: static at %.6f, %.6f (alt %.1f m)\n",
           coord.latitude, coord.longitude, [prefs[@"Altitude"] doubleValue]);
    return 0;
}

static int commandStop(void) {
    NSMutableDictionary *prefs = readPrefs();
    prefs[@"Enabled"] = @NO;
    if (!writePrefs(prefs)) return 1;
    printf("geoshim: disabled; clients see real locations again\n");
    return 0;
}

// The master switch for the app-side fallback. Independent of Enabled and of the
// per-app DisabledBundles exclusion list (chosen in Settings): with this off, no
// app installs the in-process hooks regardless of the picker. On by default.
static int commandFallback(NSArray<NSString *> *args) {
    if (args.count < 1) {
        fprintf(stderr, "geoshim: usage: geoshim fallback <on|off>\n");
        return 1;
    }
    NSMutableDictionary *prefs = readPrefs();
    NSString *v = args[0];
    if ([v isEqualToString:@"on"]) {
        prefs[@"AppFallback"] = @YES;
    } else if ([v isEqualToString:@"off"]) {
        prefs[@"AppFallback"] = @NO;
    } else {
        fprintf(stderr, "geoshim: fallback must be on or off\n");
        return 1;
    }
    if (!writePrefs(prefs)) return 1;
    printf("geoshim: app-side fallback %s (applies on each app's next launch; "
           "the locationd path is always active)\n", v.UTF8String);
    return 0;
}

// Ping the copy of the tweak inside locationd and wait briefly for it to answer.
// Returns YES if it replied (and fills *stateOut with the packed GS_STATUS_*
// word); NO means the daemon hook is not loaded or not responding. This is the
// only way the CLI can tell the tweak is actually live, rather than just echoing
// the plist it wrote.
static BOOL pingDaemon(uint64_t *stateOut, double timeoutSec) {
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

// Everything the GUI needs, computed once here so the state interpretation
// (ping, hook bits, coordinate fingerprint match) lives in one place. `serving`
// means the daemon is enabled AND its live coordinate matches the plist.
static NSDictionary *statusSnapshot(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GS_PREFS_PATH];
    uint64_t st = 0;
    BOOL alive = pingDaemon(&st, 0.7);
    BOOL daemonEnabled = (st & GS_STATUS_ENABLED) != 0;
    BOOL clHook = (st & GS_STATUS_CL_HOOK) != 0;
    BOOL visitHook = (st & GS_STATUS_VISIT_HOOK) != 0;
    BOOL hasCoord = (prefs[@"Latitude"] != nil && prefs[@"Longitude"] != nil);
    double lat = [prefs[@"Latitude"] doubleValue];
    double lon = [prefs[@"Longitude"] doubleValue];

    BOOL serving = NO;
    if (alive && daemonEnabled && hasCoord) {
        uint32_t expected = gs_coord_fingerprint(lat, lon);
        uint32_t reported = (uint32_t)((st >> GS_STATUS_FP_SHIFT) & GS_STATUS_FP_MASK);
        serving = (reported == expected);
    }
    // Effective enabled: what the daemon reports if it is live, else the plist.
    BOOL enabled = alive ? daemonEnabled : [prefs[@"Enabled"] boolValue];

    return @{
        @"daemon_alive": @(alive),
        @"enabled": @(enabled),
        @"cl_hook": @(clHook),
        @"visit_hook": @(visitHook),
        @"serving": @(serving),
        @"has_coordinate": @(hasCoord),
        @"latitude": @(lat),
        @"longitude": @(lon),
    };
}

static int commandStatusJSON(void) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:statusSnapshot() options:0 error:NULL];
    if (d) fwrite(d.bytes, 1, d.length, stdout);
    printf("\n");
    return 0;
}

static int commandStatus(NSArray<NSString *> *args) {
    if ([args containsObject:@"--json"]) return commandStatusJSON();

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:GS_PREFS_PATH];

    // Live daemon check first: this actually contacts locationd.
    uint64_t st = 0;
    if (pingDaemon(&st, 0.7)) {
        printf("daemon:      responding (locationd hook is live)\n");
        printf("  enabled:   %s\n", (st & GS_STATUS_ENABLED) ? "yes" : "no");
        printf("  cllocation hook: %s\n", (st & GS_STATUS_CL_HOOK) ? "installed" : "MISSING");
        printf("  visit hook:      %s\n", (st & GS_STATUS_VISIT_HOOK) ? "installed" : "missing");

        // Assert locationd is serving the coordinate we configured: compare the
        // fingerprint the daemon reported against the one from the plist.
        if ((st & GS_STATUS_ENABLED) && prefs && [prefs[@"Enabled"] boolValue]) {
            double lat = [prefs[@"Latitude"] doubleValue];
            double lon = [prefs[@"Longitude"] doubleValue];
            uint32_t expected = gs_coord_fingerprint(lat, lon);
            uint32_t reported = (uint32_t)((st >> GS_STATUS_FP_SHIFT) & GS_STATUS_FP_MASK);
            if (reported == expected) {
                printf("  serving configured coordinate: YES (%.5f, %.5f)\n", lat, lon);
            } else {
                printf("  serving configured coordinate: NO - locationd's value differs "
                       "from the plist (stale/not reloaded?)\n");
            }
        } else {
            printf("  serving configured coordinate: n/a (spoofing disabled)\n");
        }
    } else {
        printf("daemon:      NOT responding (tweak not loaded in locationd?)\n");
    }

    if (!prefs) {
        printf("config:      no preferences at %s (never started)\n", GS_PREFS_PATH.UTF8String);
        return 0;
    }

    printf("\nconfiguration (from prefs):\n");
    printf("state:       %s\n", [prefs[@"Enabled"] boolValue] ? "enabled" : "disabled");
    printf("coordinate:  %.6f, %.6f\n",
           [prefs[@"Latitude"] doubleValue], [prefs[@"Longitude"] doubleValue]);
    printf("altitude:    %.1f m\n", [prefs[@"Altitude"] doubleValue]);
    printf("source info: %s\n", [prefs[@"SourceInfoMode"] ?: @"nil" UTF8String]);
    printf("jitter:      %.1f m (uncertainty)\n", [prefs[@"JitterMetres"] ?: @2.0 doubleValue]);
    printf("interval:    %.2f s\n", [prefs[@"UpdateIntervalSec"] ?: @1.0 doubleValue]);
    printf("synthesize:  %s\n",
           (prefs[@"SynthesizeUpdates"] == nil || [prefs[@"SynthesizeUpdates"] boolValue]) ? "yes" : "no");

    BOOL fallbackOn = (prefs[@"AppFallback"] == nil || [prefs[@"AppFallback"] boolValue]);
    printf("app fallback:%s (normally on for every app)\n", fallbackOn ? "on" : "off");
    id excluded = prefs[@"DisabledBundles"];
    if ([excluded isKindOfClass:[NSArray class]] && [excluded count]) {
        printf("excluded apps: %lu (Settings > GeoShim > Apps)\n", (unsigned long)[excluded count]);
        for (id b in excluded) {
            if ([b isKindOfClass:[NSString class]]) printf("             - %s\n", [b UTF8String]);
        }
    } else {
        printf("excluded apps: none (every app covered)\n");
    }
    printf("prefs:       %s\n", GS_PREFS_PATH.UTF8String);
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }
        NSString *command = [NSString stringWithUTF8String:argv[1]];

        if ([command isEqualToString:@"start"])    return commandStart(args);
        if ([command isEqualToString:@"stop"])     return commandStop();
        if ([command isEqualToString:@"fallback"]) return commandFallback(args);
        if ([command isEqualToString:@"status"])   return commandStatus(args);

        usage();
        return 1;
    }
}

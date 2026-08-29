// GeoShim Settings page. The app picker is AltList's
// ATLApplicationListMultiSelectionController, driven from Root.plist (the same
// framework Choicy and Shadow use). Alongside it this controller shows a live,
// polled status readout and pushes GeoShimMapController for the map picker.
//
// All state comes from the geoshim CLI - the switch runs `geoshim start`/`stop`,
// and the status rows come from `geoshim status --json`. The CLI is the single
// source of truth (it pings the daemon and does the fingerprint match), so the
// GUI never reimplements that logic or reads a stale cfprefsd cache. Preferences'
// sandbox is lifted via libSandy so it can exec geoshim.

#import "GeoShimRootListController.h"
#import "GeoShimMapController.h"
#import "GSCommon.h"
#import <notify.h>
#import <spawn.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <sys/wait.h>

// libSandy (com.opa334.libsandy), declared inline; linked via
// GeoShimPrefs_LIBRARIES = sandy.
extern int libSandy_applyProfile(const char *profileName);
extern char **environ;

static NSString *const kGSDomain = @"xyz.regulad.geoshim";

@implementation GeoShimRootListController {
    NSString *_hookState;
    NSString *_spoofState;
    NSString *_coordinate;
    BOOL _enabled;
    NSTimer *_pollTimer;
    BOOL _observing;
    BOOL _sandyApplied;
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
    if (!_sandyApplied) {
        // Lift Preferences' sandbox so we can exec geoshim.
        libSandy_applyProfile("GeoShimSettings");
        _sandyApplied = YES;
    }
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

// Run `geoshim <args...>`, piping stdout+stderr, and return the captured text.
// Returns nil if the process could not be spawned (sandbox denied / missing) so
// callers can fall back. geoshim runs as mobile with its own no-sandbox
// entitlements; no setuid needed.
- (NSString *)runGeoshim:(NSArray<NSString *> *)args {
    NSString *binPath = jbroot(@"/usr/local/bin/geoshim");
    const char *bin = binPath.fileSystemRepresentation;

    NSUInteger n = args.count;
    char **argv = calloc(n + 2, sizeof(char *));
    if (!argv) return nil;
    argv[0] = strdup(bin);
    for (NSUInteger i = 0; i < n; i++) argv[i + 1] = strdup(args[i].UTF8String);
    argv[n + 1] = NULL;

    int outPipe[2];
    if (pipe(outPipe) != 0) {
        for (NSUInteger i = 0; i <= n; i++) free(argv[i]);
        free(argv);
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, bin, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outPipe[1]);
    for (NSUInteger i = 0; i <= n; i++) free(argv[i]);
    free(argv);

    if (rc != 0) {
        close(outPipe[0]);
        NSLog(@"[GeoShim] settings: could not exec geoshim (rc=%d) - sandbox denied?", rc);
        return nil;
    }

    NSMutableData *out = [NSMutableData data];
    char buf[1024];
    ssize_t r;
    while ((r = read(outPipe[0], buf, sizeof(buf))) > 0) [out appendBytes:buf length:(NSUInteger)r];
    close(outPipe[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
}

// Poll status via `geoshim status --json` off the main thread, then update only
// the rows whose text changed.
- (void)refreshStatus {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *out = [self runGeoshim:@[ @"status", @"--json" ]];
        NSDictionary *j = nil;
        if (out.length) {
            NSData *d = [out dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if ([parsed isKindOfClass:[NSDictionary class]]) j = parsed;
        }

        NSString *hook, *spoof, *coord;
        BOOL enabled = NO;
        if (!j) {
            hook = @"unknown"; spoof = @"unknown"; coord = @"—";
        } else {
            BOOL alive = [j[@"daemon_alive"] boolValue];
            BOOL cl = [j[@"cl_hook"] boolValue];
            BOOL visit = [j[@"visit_hook"] boolValue];
            BOOL serving = [j[@"serving"] boolValue];
            BOOL hasCoord = [j[@"has_coordinate"] boolValue];
            enabled = [j[@"enabled"] boolValue];

            hook = !alive ? @"not loaded"
                 : !cl    ? @"loaded, CLLocation hook MISSING"
                 : !visit ? @"loaded (no visit hook)"
                 :          @"loaded";
            spoof = !alive   ? @"unknown (daemon not responding)"
                  : !enabled ? @"off"
                  : serving  ? @"on"
                  :            @"on (daemon coordinate differs)";
            coord = hasCoord ? [NSString stringWithFormat:@"%.5f, %.5f",
                                [j[@"latitude"] doubleValue], [j[@"longitude"] doubleValue]]
                             : @"—";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            _enabled = enabled;
            if (![hook isEqualToString:_hookState]) {
                _hookState = hook;
                PSSpecifier *s = [self specifierForID:@"statusHook"];
                if (s) [self reloadSpecifier:s animated:NO];
            }
            if (![spoof isEqualToString:_spoofState]) {
                _spoofState = spoof;
                PSSpecifier *s = [self specifierForID:@"statusSpoofing"];
                if (s) [self reloadSpecifier:s animated:NO];
            }
            if (![coord isEqualToString:_coordinate]) {
                _coordinate = coord;
                PSSpecifier *s = [self specifierForID:@"statusCoordinate"];
                if (s) [self reloadSpecifier:s animated:NO];
            }
            PSSpecifier *sw = [self specifierForID:@"enabledSwitch"];
            if (sw) [self reloadSpecifier:sw animated:NO];
        });
    });
}

// prefsChanged (from the CLI or our own switch) - refresh at once.
- (void)onExternalChange {
    [self refreshStatus];
}

#pragma mark - Enabled switch (drives the geoshim CLI)

- (id)getEnabled:(PSSpecifier *)specifier {
    return @(_enabled);
}

// Run the real CLI: `geoshim start` (resumes the saved coordinate) / `geoshim
// stop`. geoshim writes the prefs and posts the reload; the daemon then
// self-restarts. If the exec is denied, fall back to a synchronized pref write +
// notify (still triggers the daemon self-restart).
- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    BOOL on = [value boolValue];
    _enabled = on;   // optimistic; refreshStatus reconciles with the daemon
    NSString *out = [self runGeoshim:@[ on ? @"start" : @"stop" ]];
    if (out) {
        NSLog(@"[GeoShim] settings: geoshim %@ -> %@", on ? @"start" : @"stop",
              [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    } else {
        CFPreferencesSetAppValue(CFSTR("Enabled"),
                                 on ? kCFBooleanTrue : kCFBooleanFalse,
                                 (__bridge CFStringRef)kGSDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kGSDomain);
        notify_post(GS_NOTIFY_NAME);
    }
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
    return _coordinate ?: @"…";
}

#pragma mark - Map picker (Root.plist `action`)

- (void)openMap {
    GeoShimMapController *map = [[GeoShimMapController alloc] init];
    [self.navigationController pushViewController:map animated:YES];
}

@end

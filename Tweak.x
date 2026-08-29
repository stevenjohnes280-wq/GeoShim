// GeoShim - system-wide location substitution.
//
// The tweak loads into two kinds of process and splits at load time
// (gs_isLocationd()):
//
//   * locationd (the daemon)  - the primary path. Positions are handed to every
//     client as an NSSecureCoding keyed archive over XPC, so
//     -[CLLocation encodeWithCoder:] is the one point where an outbound fix is
//     serialised. Hooking it there reaches even a client whose own in-process
//     injection is blacklisted by roothide - the whole reason for the daemon
//     path. CLVisit is rewritten on the same delivery path.
//
//   * an ordinary app (the app-side fallback) - the redundancy path. In apps
//     that DO permit injection it hooks CLLocationManager directly, which gives
//     an update timer the daemon cannot (spoofed callbacks even when the real
//     subsystem is silent). It is gated by the AppFallback pref (on by default,
//     read at load) and never touches the daemon path.
//
// Everything fails open. If any step throws or returns nil, the real location
// is delivered untouched.

#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <os/lock.h>
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <unistd.h>

#import "GSCommon.h"
#import "GSConfig.h"
#import "GSLocationFactory.h"

// From libSandy (com.opa334.libsandy), the roothide fork. Declared inline so no
// header install is needed; linked via GeoShim_LIBRARIES = sandy. Only the
// app-side branch calls it.
extern int libSandy_applyProfile(const char *profileName);

#pragma mark - Process guard

// The filter targets the locationd executable and CLLocationManager-using apps.
// gs_isLocationd() decides which half of this file installs.
static BOOL gs_isLocationd(void) {
    const char *name = getprogname();
    return name && strcmp(name, "locationd") == 0;
}

#pragma mark - Daemon hook (locationd): CLLocation

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
    GSLog(@"locationd: CLLocation encodeWithCoder: hook installed");
}

#pragma mark - Daemon hook (locationd): CLVisit

// CLVisit carries its own coordinate and is delivered by the same keyed-archive
// path, so a visit-monitoring app would otherwise see the real place. We rewrite
// the coordinate on a *copy* (never mutating the daemon's own object) and encode
// that. CLVisit has no public initializer, so we reach the coordinate through
// its ivar; the offset is discovered at load and the hook is not installed at
// all if the layout is not what we expect (fail closed -> real visit encoded).
static IMP gVisitEncodeOrig = NULL;
static ptrdiff_t gVisitCoordOffset = -1;              // CLLocationCoordinate2D
static ptrdiff_t gVisitLatOffset = -1, gVisitLonOffset = -1;  // fallback: 2 doubles

static void gs_visitEncodeWithCoder(id self, SEL _cmd, NSCoder *coder) {
    @try {
        GSLocationFactory *factory = [GSLocationFactory shared];
        if (factory.active && [self isKindOfClass:[CLVisit class]]) {
            CLLocation *fake = [factory spoofedLocationFromReal:nil];
            if (fake && CLLocationCoordinate2DIsValid(fake.coordinate)) {
                CLVisit *copy = [(CLVisit *)self copy];
                if (copy) {
                    uint8_t *base = (uint8_t *)(__bridge void *)copy;
                    BOOL wrote = NO;
                    if (gVisitCoordOffset >= 0) {
                        *(CLLocationCoordinate2D *)(base + gVisitCoordOffset) = fake.coordinate;
                        wrote = YES;
                    } else if (gVisitLatOffset >= 0 && gVisitLonOffset >= 0) {
                        *(double *)(base + gVisitLatOffset) = fake.coordinate.latitude;
                        *(double *)(base + gVisitLonOffset) = fake.coordinate.longitude;
                        wrote = YES;
                    }
                    if (wrote && gVisitEncodeOrig) {
                        if (GEOSHIM_DEBUG_BUILD) {
                            GSLog(@"locationd: visit -> %f,%f",
                                  fake.coordinate.latitude, fake.coordinate.longitude);
                        }
                        ((void (*)(id, SEL, NSCoder *))gVisitEncodeOrig)(copy, _cmd, coder);
                        return;
                    }
                }
            }
        }
    } @catch (NSException *e) {
        GSLog(@"locationd: CLVisit encode substitution failed: %@", e);
    }

    if (gVisitEncodeOrig) {
        ((void (*)(id, SEL, NSCoder *))gVisitEncodeOrig)(self, _cmd, coder);
    }
}

static void gs_installVisitHook(void) {
    Class c = [CLVisit class];
    if (!c) return;

    Ivar coord = class_getInstanceVariable(c, "_coordinate");
    if (coord) {
        gVisitCoordOffset = ivar_getOffset(coord);
    } else {
        Ivar la = class_getInstanceVariable(c, "_latitude");
        Ivar lo = class_getInstanceVariable(c, "_longitude");
        if (la && lo) {
            gVisitLatOffset = ivar_getOffset(la);
            gVisitLonOffset = ivar_getOffset(lo);
        }
    }

    if (gVisitCoordOffset < 0 && (gVisitLatOffset < 0 || gVisitLonOffset < 0)) {
        GSLog(@"locationd: CLVisit coordinate ivar not found; visits left unspoofed");
        return;
    }

    Method m = class_getInstanceMethod(c, @selector(encodeWithCoder:));
    if (!m) {
        GSLog(@"locationd: CLVisit has no encodeWithCoder:; visit hook not installed");
        return;
    }
    gVisitEncodeOrig = method_getImplementation(m);
    method_setImplementation(m, (IMP)gs_visitEncodeWithCoder);
    GSLog(@"locationd: CLVisit encodeWithCoder: hook installed (coordOffset=%ld latOffset=%ld)",
          (long)gVisitCoordOffset, (long)gVisitLatOffset);
}

#pragma mark - Daemon hook (locationd): status responder

// Answers the CLI's liveness ping. The CLI cannot otherwise tell whether this
// tweak is actually loaded in locationd; `geoshim status` posts a request and
// waits for us to answer. We pack our live state into the reply name so the CLI
// learns not just that we are alive but what the daemon itself believes.
static int gStatusReplyToken = -1;

static void gs_answerStatusRequest(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    @try {
        GSConfig *cfg = [GSConfig current];
        uint64_t state = GS_STATUS_ALIVE;
        if (cfg.enabled)              state |= GS_STATUS_ENABLED;
        if (gEncodeWithCoderOrig)     state |= GS_STATUS_CL_HOOK;
        if (gVisitEncodeOrig)         state |= GS_STATUS_VISIT_HOOK;
        // Report the coordinate we are actively serving so the CLI/Settings can
        // assert locationd holds the configured value.
        if (cfg.enabled && CLLocationCoordinate2DIsValid(cfg.coordinate)) {
            uint32_t fp = gs_coord_fingerprint(cfg.coordinate.latitude, cfg.coordinate.longitude);
            state |= ((uint64_t)fp << GS_STATUS_FP_SHIFT);
        }
        if (gStatusReplyToken != -1) notify_set_state(gStatusReplyToken, state);
    } @catch (NSException *e) {
        GSLog(@"locationd: status request handler threw %@", e);
    }
    notify_post(GS_NOTIFY_STATUS_REPLY);
}

static void gs_installStatusResponder(void) {
    // A registration (any kind) is required before notify_set_state accepts the
    // name; check-registration gives us a token without a callback.
    uint32_t r = notify_register_check(GS_NOTIFY_STATUS_REPLY, &gStatusReplyToken);
    if (r != NOTIFY_STATUS_OK) {
        gStatusReplyToken = -1;
        GSLog(@"locationd: could not register status reply (%u)", r);
    }
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, gs_answerStatusRequest,
                                    CFSTR(GS_NOTIFY_STATUS_REQ),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}

#pragma mark - App-side fallback: shared state

// The delegate class lives in the host app, so its callbacks cannot be %hooked
// by name. On first sight of a delegate we swizzle its class's callbacks once
// and remember the original IMP (keyed by a pointer to the class). A synthetic
// timer per manager delivers spoofed fixes on a cadence so the app still moves
// when the real subsystem is silent (permission denied, GPS cold, or a poll-only
// client). All state below is touched only in app processes.
static dispatch_queue_t gClientQueue = NULL;
static os_unfair_lock gClientLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSValue *, NSValue *> *gModernOrig = nil;  // Class* -> IMP for didUpdateLocations:
static NSMutableDictionary<NSValue *, NSValue *> *gLegacyOrig = nil;  // Class* -> IMP for didUpdateToLocation:fromLocation:
static NSHashTable<CLLocationManager *> *gManagers = nil;            // every manager seen (weak)

// Per-manager associated state.
static const void *kGSTimerKey = &kGSTimerKey;      // dispatch_source_t
static const void *kGSLastRealKey = &kGSLastRealKey; // NSNumber (CFAbsoluteTime)
static const void *kGSWantsKey = &kGSWantsKey;      // NSNumber (BOOL): startUpdatingLocation is active

static IMP gs_lookupOrig(NSMutableDictionary *map, Class cls) {
    IMP found = NULL;
    os_unfair_lock_lock(&gClientLock);
    for (Class k = cls; k; k = class_getSuperclass(k)) {
        NSValue *v = map[[NSValue valueWithPointer:(__bridge void *)k]];
        if (v) { found = (IMP)[v pointerValue]; break; }
    }
    os_unfair_lock_unlock(&gClientLock);
    return found;
}

static void gs_registerManager(CLLocationManager *m) {
    if (!m) return;
    os_unfair_lock_lock(&gClientLock);
    [gManagers addObject:m];
    os_unfair_lock_unlock(&gClientLock);
}

static void gs_noteRealForManager(CLLocationManager *m) {
    if (!m) return;
    objc_setAssociatedObject(m, kGSLastRealKey, @(CFAbsoluteTimeGetCurrent()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CFAbsoluteTime gs_lastReal(CLLocationManager *m) {
    NSNumber *n = objc_getAssociatedObject(m, kGSLastRealKey);
    return n ? n.doubleValue : 0.0;
}

static void gs_setWantsUpdates(CLLocationManager *m, BOOL v) {
    objc_setAssociatedObject(m, kGSWantsKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL gs_wantsUpdates(CLLocationManager *m) {
    NSNumber *n = objc_getAssociatedObject(m, kGSWantsKey);
    return n.boolValue;
}

#pragma mark - App-side fallback: delegate swizzles

// Replacement for -locationManager:didUpdateLocations: on the delegate class.
// Substitutes every CLLocation in the array, then calls the original IMP. When
// spoofing is off, passes the real array straight through.
static void gs_didUpdateLocations(id self, SEL _cmd, CLLocationManager *manager, NSArray *locations) {
    IMP orig = gs_lookupOrig(gModernOrig, object_getClass(self));
    @try {
        GSLocationFactory *factory = [GSLocationFactory shared];
        if (factory.active && [locations isKindOfClass:[NSArray class]] && locations.count) {
            gs_noteRealForManager(manager);
            NSMutableArray *out = [NSMutableArray arrayWithCapacity:locations.count];
            for (CLLocation *loc in locations) {
                if ([loc isKindOfClass:[CLLocation class]] &&
                    CLLocationCoordinate2DIsValid(loc.coordinate)) {
                    [factory noteRealLocation:loc];
                    CLLocation *fake = [factory spoofedLocationFromReal:loc];
                    [out addObject:fake ?: loc];
                } else {
                    [out addObject:loc];
                }
            }
            if (orig) {
                ((void (*)(id, SEL, CLLocationManager *, NSArray *))orig)(self, _cmd, manager, out);
                return;
            }
        }
    } @catch (NSException *e) {
        GSLog(@"app: didUpdateLocations substitution failed: %@", e);
    }
    if (orig) ((void (*)(id, SEL, CLLocationManager *, NSArray *))orig)(self, _cmd, manager, locations);
}

// Replacement for the legacy -locationManager:didUpdateToLocation:fromLocation:.
static void gs_didUpdateToLocation(id self, SEL _cmd, CLLocationManager *manager,
                                   CLLocation *newLoc, CLLocation *oldLoc) {
    IMP orig = gs_lookupOrig(gLegacyOrig, object_getClass(self));
    @try {
        GSLocationFactory *factory = [GSLocationFactory shared];
        if (factory.active && [newLoc isKindOfClass:[CLLocation class]] &&
            CLLocationCoordinate2DIsValid(newLoc.coordinate)) {
            gs_noteRealForManager(manager);
            [factory noteRealLocation:newLoc];
            CLLocation *fake = [factory spoofedLocationFromReal:newLoc];
            if (orig) {
                ((void (*)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *))orig)
                    (self, _cmd, manager, fake ?: newLoc, oldLoc);
                return;
            }
        }
    } @catch (NSException *e) {
        GSLog(@"app: didUpdateToLocation substitution failed: %@", e);
    }
    if (orig) ((void (*)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *))orig)
                  (self, _cmd, manager, newLoc, oldLoc);
}

// Swizzle one selector on a delegate class exactly once, recording the original
// (own or inherited) IMP so the replacement and the synthetic timer can both
// reach it. class_replaceMethod adds an own implementation when the class only
// inherited one; the IMP to keep is then the inherited one captured first.
static void gs_swizzleSelector(Class cls, SEL sel, IMP replacement, NSMutableDictionary *map) {
    if (!cls) return;
    NSValue *key = [NSValue valueWithPointer:(__bridge void *)cls];

    os_unfair_lock_lock(&gClientLock);
    BOOL already = map[key] != nil;
    os_unfair_lock_unlock(&gClientLock);
    if (already) return;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;   // the delegate does not implement this callback at all
    const char *types = method_getTypeEncoding(m);
    IMP inherited = class_getMethodImplementation(cls, sel);
    IMP prev = class_replaceMethod(cls, sel, replacement, types);
    IMP orig = prev ? prev : inherited;

    os_unfair_lock_lock(&gClientLock);
    if (!map[key]) map[key] = [NSValue valueWithPointer:(void *)orig];
    os_unfair_lock_unlock(&gClientLock);
    GSLog(@"app: swizzled %s on %s", sel_getName(sel), class_getName(cls));
}

static void gs_swizzleDelegateClass(Class cls) {
    gs_swizzleSelector(cls, @selector(locationManager:didUpdateLocations:),
                       (IMP)gs_didUpdateLocations, gModernOrig);
    gs_swizzleSelector(cls, @selector(locationManager:didUpdateToLocation:fromLocation:),
                       (IMP)gs_didUpdateToLocation, gLegacyOrig);
}

#pragma mark - App-side fallback: synthetic update timer

// Deliver one spoofed fix to the manager's delegate, unless a real callback
// landed within the last 1.5 intervals (so the app is never fed two fixes for
// one moment). We call the delegate's ORIGINAL IMP directly, so our own
// delivery is never mistaken for a real one and never re-substituted.
static void gs_deliverSynthetic(CLLocationManager *manager) {
    GSLocationFactory *factory = [GSLocationFactory shared];
    if (!factory.active) return;
    GSConfig *cfg = [GSConfig current];
    if (!cfg.synthesizeUpdates) return;

    double interval = cfg.updateInterval > 0 ? cfg.updateInterval : 1.0;
    if (CFAbsoluteTimeGetCurrent() - gs_lastReal(manager) < 1.5 * interval) return;

    CLLocation *fake = [factory spoofedLocationFromReal:nil];
    if (!fake || !CLLocationCoordinate2DIsValid(fake.coordinate)) return;

    id delegate = manager.delegate;
    if (!delegate) return;
    NSArray *locs = @[fake];

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Class dc = object_getClass(delegate);
            IMP orig = gs_lookupOrig(gModernOrig, dc);
            if (orig && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                ((void (*)(id, SEL, CLLocationManager *, NSArray *))orig)
                    (delegate, @selector(locationManager:didUpdateLocations:), manager, locs);
                return;
            }
            IMP lorig = gs_lookupOrig(gLegacyOrig, dc);
            if (lorig && [delegate respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
                ((void (*)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *))lorig)
                    (delegate, @selector(locationManager:didUpdateToLocation:fromLocation:), manager, fake, fake);
            }
        } @catch (NSException *e) {
            GSLog(@"app: synthetic delivery failed: %@", e);
        }
    });
}

static void gs_startTimer(CLLocationManager *manager) {
    GSConfig *cfg = [GSConfig current];
    if (!cfg.synthesizeUpdates) return;
    if (objc_getAssociatedObject(manager, kGSTimerKey)) return;   // already running

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gClientQueue);
    if (!t) return;
    double interval = cfg.updateInterval > 0 ? cfg.updateInterval : 1.0;
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak CLLocationManager *weakManager = manager;
    dispatch_source_set_event_handler(t, ^{
        @autoreleasepool {
            CLLocationManager *strong = weakManager;
            if (strong) gs_deliverSynthetic(strong);
        }
    });
    objc_setAssociatedObject(manager, kGSTimerKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_resume(t);
}

static void gs_stopTimer(CLLocationManager *manager) {
    dispatch_source_t t = objc_getAssociatedObject(manager, kGSTimerKey);
    if (t) {
        dispatch_source_cancel(t);
        objc_setAssociatedObject(manager, kGSTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Apply the current config to every manager seen so far: start a timer where
// spoofing is now active and updates are wanted, stop it otherwise. This is what
// makes a live `geoshim start`/`stop` take effect without relaunching the app.
static void gs_reconcileManagers(void) {
    BOOL active = [GSLocationFactory shared].active;
    NSArray<CLLocationManager *> *snapshot;
    os_unfair_lock_lock(&gClientLock);
    snapshot = gManagers.allObjects;
    os_unfair_lock_unlock(&gClientLock);
    for (CLLocationManager *m in snapshot) {
        if (active && gs_wantsUpdates(m)) gs_startTimer(m);
        else gs_stopTimer(m);
    }
}

#pragma mark - App-side fallback: CLLocationManager hooks

%group GSClientHooks

%hook CLLocationManager

- (void)setDelegate:(id<CLLocationManagerDelegate>)delegate {
    %orig(delegate);
    @try {
        gs_registerManager(self);
        if (delegate) gs_swizzleDelegateClass(object_getClass(delegate));
    } @catch (NSException *e) {
        GSLog(@"app: setDelegate hook failed: %@", e);
    }
}

// For apps that poll -location rather than subscribe.
- (CLLocation *)location {
    CLLocation *real = %orig;
    @try {
        GSLocationFactory *factory = [GSLocationFactory shared];
        if (!factory.active) return real;
        if (real) [factory noteRealLocation:real];
        CLLocation *fake = [factory spoofedLocationFromReal:real];
        return fake ?: real;
    } @catch (NSException *e) {
        GSLog(@"app: -location hook failed: %@", e);
        return real;
    }
}

- (void)startUpdatingLocation {
    %orig;
    @try {
        gs_registerManager(self);
        gs_setWantsUpdates(self, YES);
        if ([GSLocationFactory shared].active) gs_startTimer(self);
    } @catch (NSException *e) {
        GSLog(@"app: startUpdatingLocation hook failed: %@", e);
    }
}

- (void)stopUpdatingLocation {
    %orig;
    @try {
        gs_setWantsUpdates(self, NO);
        gs_stopTimer(self);
    } @catch (NSException *e) {
        GSLog(@"app: stopUpdatingLocation hook failed: %@", e);
    }
}

- (void)requestLocation {
    %orig;
    @try {
        gs_registerManager(self);
        if ([GSLocationFactory shared].active) {
            // One-shot: deliver a spoofed fix shortly if no real one arrives
            // first (gs_deliverSynthetic self-suppresses if a real fix landed).
            double interval = [GSConfig current].updateInterval;
            CLLocationManager *manager = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((interval > 0 ? interval : 1.0) * NSEC_PER_SEC)),
                           gClientQueue, ^{ gs_deliverSynthetic(manager); });
        }
    } @catch (NSException *e) {
        GSLog(@"app: requestLocation hook failed: %@", e);
    }
}

%end   // %hook CLLocationManager

%end   // %group GSClientHooks

#pragma mark - Preferences reload

// Snapshot of the last coordinate/enabled the daemon acted on, so we only bounce
// locationd when the position or on/off state actually changes.
static int gDaemonPrevEnabled = -1;
static double gDaemonPrevLat = 1e9, gDaemonPrevLon = 1e9;

// Live re-delivery through encodeWithCoder: reaches third-party clients, but some
// first-party consumers (Apple Maps) cache a fix from a path that does not
// re-serialize and so keep showing the old location. Bouncing locationd forces
// every client to re-register and re-grab, which is the only reliable way to make
// a coordinate change take hold everywhere. Guarded to real changes so ordinary
// prefs edits do not thrash the daemon. SIGKILL matches `killall -9 locationd`;
// launchd relaunches immediately and the fresh instance reads the new prefs.
static void gs_restartLocationdIfCoordinateChanged(void) {
    GSConfig *c = [GSConfig current];
    BOOL changed = (gDaemonPrevEnabled != (int)c.enabled) ||
                   (c.enabled && CLLocationCoordinate2DIsValid(c.coordinate) &&
                    (gDaemonPrevLat != c.coordinate.latitude ||
                     gDaemonPrevLon != c.coordinate.longitude));
    gDaemonPrevEnabled = (int)c.enabled;
    gDaemonPrevLat = c.coordinate.latitude;
    gDaemonPrevLon = c.coordinate.longitude;
    if (!changed) return;

    // Synchronous SIGKILL: no dispatch dependency at all. launchd relaunches a
    // fresh locationd that reads the new prefs, so every client re-registers and
    // re-grabs. This is the reliable way to make a change take hold everywhere;
    // guarded above to real coordinate/enabled changes so we do not thrash.
    GSLog(@"locationd: config changed - SIGKILL self now (launchd relaunches with the new fix)");
    kill(getpid(), SIGKILL);
}

static void gs_prefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    @try {
        [GSConfig reload];
        // Harmless in locationd (no managers were ever registered there).
        gs_reconcileManagers();
        if (gs_isLocationd()) gs_restartLocationdIfCoordinateChanged();
    } @catch (NSException *e) {
        GSLog(@"prefs: reload threw %@", e);
    }
}

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        BOOL isDaemon = gs_isLocationd();

        // Non-app processes (the geoshim CLI, or any command-line tool that merely
        // links CoreLocation and so matches the Classes filter) have no main-bundle
        // identifier and nothing to spoof - register nothing and install nothing,
        // so they stay completely silent.
        if (!isDaemon && NSBundle.mainBundle.bundleIdentifier.length == 0) return;

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, gs_prefsChanged,
                                        CFSTR(GS_NOTIFY_NAME),
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);

        if (isDaemon) {
            gs_installDaemonHook();
            gs_installVisitHook();
            gs_installStatusResponder();

            GSConfig *config = [GSConfig current];
            // Seed the change snapshot with what we loaded, so the first prefs
            // edit is compared against reality rather than triggering a spurious
            // bounce right after launch.
            gDaemonPrevEnabled = (int)config.enabled;
            gDaemonPrevLat = config.coordinate.latitude;
            gDaemonPrevLon = config.coordinate.longitude;
            GSLog(@"loaded in locationd (enabled=%d srcinfo=%ld strategy=%@)",
                  config.enabled, (long)config.sourceInfoMode,
                  [[GSLocationFactory shared] sourceInfoStrategyDescription]);
            return;
        }

        // App process. Lift the sandbox first so the prefs read below (and the
        // hooks' reads later) can see our plist from inside a sandboxed app;
        // this must precede the first GSConfig read. Harmless if the app's
        // sandbox already permits the read or if libSandy is unavailable.
        int sandy = libSandy_applyProfile("GeoShim");
        GSLog(@"app: libSandy_applyProfile(GeoShim) = %d in %@",
              sandy, NSProcessInfo.processInfo.processName);

        // Install the fallback only for apps switched on in the AltList picker,
        // and only while the master toggle is on (both default per VPNHide's
        // model: master on, list empty). The gate is read at load; changing it
        // takes effect on the app's next launch, since an installed %hook cannot
        // be cleanly removed.
        GSConfig *config = [GSConfig current];
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![config appFallbackEnabledForBundle:bundleID]) {
            GSLog(@"app fallback excluded for %@ (master=%d, %lu app(s) excluded)",
                  bundleID, config.appFallback, (unsigned long)config.disabledBundles.count);
            return;
        }

        gClientQueue = dispatch_queue_create("xyz.regulad.geoshim.client", DISPATCH_QUEUE_SERIAL);
        gModernOrig = [NSMutableDictionary dictionary];
        gLegacyOrig = [NSMutableDictionary dictionary];
        gManagers = [NSHashTable weakObjectsHashTable];

        %init(GSClientHooks);
        GSLog(@"app fallback installed for %@ (enabled=%d)", bundleID, config.enabled);
    }
}

#import "GSLocationFactory.h"
#import "GSRouteEngine.h"
#import "GSConfig.h"
#import "GSCommon.h"
#import <os/lock.h>
#import <objc/runtime.h>

#pragma mark - sourceInformation attachment

// A CLLocation built through the public initializer reports
// sourceInformation == nil, which is what SourceInfoMode == nil wants and
// needs no private API at all. The other two modes need a way to attach an
// object. Two strategies, resolved once at first use:
//
//   1. A private initializer that takes the source info directly. Its exact
//      selector is not documented, so it is probed by name AND validated
//      against its own NSMethodSignature before being called. If the shape
//      does not match what we would pass, it is rejected.
//   2. A CLLocation subclass overriding -sourceInformation. Always available,
//      but object_getClass() on the result is GSLocation rather than
//      CLLocation, which is itself a tell (see README, Known limits).
typedef NS_ENUM(NSInteger, GSAttachStrategy) {
    GSAttachStrategyUnresolved = 0,
    GSAttachStrategyPrivateInit,
    GSAttachStrategySubclass,
};

@interface GSLocation : CLLocation
@property (nonatomic, strong) CLLocationSourceInformation *gsSourceInformation;
@end

@implementation GSLocation
- (CLLocationSourceInformation *)sourceInformation {
    return _gsSourceInformation;
}
@end

static SEL gGSSourceInfoInitSel = NULL;
static GSAttachStrategy gGSStrategy = GSAttachStrategyUnresolved;

// Accepts the selector only if its signature is exactly the public
// designated initializer plus one trailing object argument.
static BOOL gs_signatureMatches(SEL sel) {
    NSMethodSignature *sig = nil;
    @try {
        sig = [CLLocation instanceMethodSignatureForSelector:sel];
    } @catch (NSException *e) {
        return NO;
    }
    if (!sig || sig.numberOfArguments != 12) return NO;

    const char *coordType = [sig getArgumentTypeAtIndex:2];
    if (!coordType || coordType[0] != '{') return NO;     // CLLocationCoordinate2D
    for (NSUInteger i = 3; i <= 9; i++) {                 // seven doubles
        const char *t = [sig getArgumentTypeAtIndex:i];
        if (!t || t[0] != 'd') return NO;
    }
    const char *tsType = [sig getArgumentTypeAtIndex:10];  // NSDate *
    const char *srcType = [sig getArgumentTypeAtIndex:11];  // source info
    if (!tsType || tsType[0] != '@') return NO;
    if (!srcType || srcType[0] != '@') return NO;
    return YES;
}

static void gs_resolveStrategy(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *candidates = @[
            @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:courseAccuracy:speed:speedAccuracy:timestamp:sourceInfo:",
            @"initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:course:courseAccuracy:speed:speedAccuracy:timestamp:sourceInformation:",
        ];
        for (NSString *name in candidates) {
            SEL sel = NSSelectorFromString(name);
            if (!sel) continue;
            if (![CLLocation instancesRespondToSelector:sel]) continue;
            if (!gs_signatureMatches(sel)) {
                GSLog(@"factory: %@ exists but its signature does not match; skipping", name);
                continue;
            }
            gGSSourceInfoInitSel = sel;
            gGSStrategy = GSAttachStrategyPrivateInit;
            GSLog(@"factory: sourceInformation via private initializer %@", name);
            return;
        }
        gGSStrategy = GSAttachStrategySubclass;
        GSLog(@"factory: sourceInformation via CLLocation subclass");
    });
}

// Builds a CLLocation with no sourceInformation. Public API only.
static CLLocation *gs_plainLocation(CLLocationCoordinate2D coord,
                                    CLLocationDistance altitude,
                                    CLLocationAccuracy hAcc,
                                    CLLocationAccuracy vAcc,
                                    CLLocationDirection course,
                                    CLLocationDirectionAccuracy courseAcc,
                                    CLLocationSpeed speed,
                                    CLLocationSpeedAccuracy speedAcc,
                                    NSDate *timestamp) {
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:altitude
                               horizontalAccuracy:hAcc
                                 verticalAccuracy:vAcc
                                           course:course
                                    courseAccuracy:courseAcc
                                            speed:speed
                                     speedAccuracy:speedAcc
                                         timestamp:timestamp];
}

static CLLocation *gs_locationWithSourceInfo(CLLocationCoordinate2D coord,
                                             CLLocationDistance altitude,
                                             CLLocationAccuracy hAcc,
                                             CLLocationAccuracy vAcc,
                                             CLLocationDirection course,
                                             CLLocationDirectionAccuracy courseAcc,
                                             CLLocationSpeed speed,
                                             CLLocationSpeedAccuracy speedAcc,
                                             NSDate *timestamp,
                                             CLLocationSourceInformation *sourceInfo) {
    if (!sourceInfo) {
        return gs_plainLocation(coord, altitude, hAcc, vAcc, course, courseAcc,
                                speed, speedAcc, timestamp);
    }

    gs_resolveStrategy();

    if (gGSStrategy == GSAttachStrategyPrivateInit && gGSSourceInfoInitSel) {
        @try {
            NSMethodSignature *sig = [CLLocation instanceMethodSignatureForSelector:gGSSourceInfoInitSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = gGSSourceInfoInitSel;

            CLLocation *fresh = [CLLocation alloc];
            inv.target = fresh;
            [inv setArgument:&coord atIndex:2];
            [inv setArgument:&altitude atIndex:3];
            [inv setArgument:&hAcc atIndex:4];
            [inv setArgument:&vAcc atIndex:5];
            [inv setArgument:&course atIndex:6];
            [inv setArgument:&courseAcc atIndex:7];
            [inv setArgument:&speed atIndex:8];
            [inv setArgument:&speedAcc atIndex:9];
            [inv setArgument:&timestamp atIndex:10];
            [inv setArgument:&sourceInfo atIndex:11];
            [inv invoke];

            void *raw = NULL;
            [inv getReturnValue:&raw];
            CLLocation *result = (__bridge CLLocation *)raw;
            if ([result isKindOfClass:[CLLocation class]]) return result;
            GSLog(@"factory: private initializer returned %@; falling back", result);
        } @catch (NSException *e) {
            GSLog(@"factory: private initializer threw %@; falling back to subclass", e);
            gGSStrategy = GSAttachStrategySubclass;
        }
    }

    GSLocation *loc = [[GSLocation alloc] initWithCoordinate:coord
                                                    altitude:altitude
                                          horizontalAccuracy:hAcc
                                            verticalAccuracy:vAcc
                                                      course:course
                                               courseAccuracy:courseAcc
                                                       speed:speed
                                                speedAccuracy:speedAcc
                                                    timestamp:timestamp];
    loc.gsSourceInformation = sourceInfo;
    return loc;
}

#pragma mark - Noise

// Box-Muller. arc4random_uniform avoids seeding entirely.
static double gs_gaussian(double mean, double stddev) {
    double u1 = ((double)arc4random_uniform(UINT32_MAX - 1) + 1.0) / (double)UINT32_MAX;
    double u2 = ((double)arc4random_uniform(UINT32_MAX)) / (double)UINT32_MAX;
    return mean + stddev * sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

static double gs_clamp(double v, double lo, double hi) {
    return fmin(hi, fmax(lo, v));
}

#pragma mark - Factory

@implementation GSLocationFactory {
    os_unfair_lock _lock;
    double _hAcc;
    double _vAcc;
    CLLocation *_lastReal;
    NSDate *_lastRealLogged;
    CLLocationSourceInformation *_cleanSourceInfo;
}

+ (instancetype)shared {
    static GSLocationFactory *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[GSLocationFactory alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        // Start somewhere plausible for an open-sky fix and wander from there.
        _hAcc = gs_clamp(gs_gaussian(9.0, 3.0), 5.0, 65.0);
        _vAcc = gs_clamp(gs_gaussian(5.0, 1.5), 3.0, 10.0);
    }
    return self;
}

- (BOOL)active {
    return [GSConfig current].enabled;
}

- (NSString *)sourceInfoStrategyDescription {
    gs_resolveStrategy();
    switch (gGSStrategy) {
        case GSAttachStrategyPrivateInit:
            return [NSString stringWithFormat:@"private-init(%@)",
                    NSStringFromSelector(gGSSourceInfoInitSel)];
        case GSAttachStrategySubclass:
            return @"subclass";
        default:
            return @"unresolved";
    }
}

- (void)noteRealLocation:(CLLocation *)real {
    if (![real isKindOfClass:[CLLocation class]]) return;

    // While disabled we hold on to nothing and do nothing, so an installed
    // but switched-off tweak leaves no trace on the app it is loaded into.
    GSConfig *config = [GSConfig current];
    if (!config.enabled && !config.logRealFixes) return;

    os_unfair_lock_lock(&_lock);
    _lastReal = real;
    BOOL shouldLog = NO;
    if (GEOSHIM_DEBUG_BUILD && config.logRealFixes) {
        NSDate *now = [NSDate date];
        if (!_lastRealLogged || [now timeIntervalSinceDate:_lastRealLogged] > 5.0) {
            _lastRealLogged = now;
            shouldLog = YES;
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (shouldLog) {
        // Section 4.1 probe: what does a genuine fix report on this device?
        CLLocationSourceInformation *info = real.sourceInformation;
        GSLog(@"real fix: coord=%f,%f hAcc=%.1f vAcc=%.1f alt=%.1f speed=%.2f "
              @"speedAcc=%.2f course=%.1f courseAcc=%.1f class=%@ sourceInfo=%@ sim=%d acc=%d",
              real.coordinate.latitude, real.coordinate.longitude,
              real.horizontalAccuracy, real.verticalAccuracy, real.altitude,
              real.speed, real.speedAccuracy, real.course, real.courseAccuracy,
              NSStringFromClass(object_getClass(real)), info,
              info ? info.isSimulatedBySoftware : -1,
              info ? info.isProducedByAccessory : -1);
    }
}

// Caller must hold _lock.
- (CLLocationSourceInformation *)sourceInfoForMode:(GSSourceInfoMode)mode {
    switch (mode) {
        case GSSourceInfoModeNil:
            return nil;
        case GSSourceInfoModeClean:
            if (!_cleanSourceInfo) {
                _cleanSourceInfo = [[CLLocationSourceInformation alloc]
                                    initWithSoftwareSimulationState:NO
                                          andExternalAccessoryState:NO];
            }
            return _cleanSourceInfo;
        case GSSourceInfoModePassthrough:
            return _lastReal.sourceInformation;
    }
    return nil;
}

- (CLLocation *)spoofedLocationFromReal:(CLLocation *)real {
    GSConfig *config = [GSConfig current];
    if (!config.enabled) return nil;

    @try {
        NSDate *now = [NSDate date];

        CLLocationCoordinate2D base = config.coordinate;
        CLLocationDirection course = -1.0;
        CLLocationSpeed speed = 0.0;
        BOOL moving = NO;

        if (config.mode == GSModeRoute) {
            GSRouteSample s = [[GSRouteEngine shared] sampleForConfig:config atDate:now];
            if (s.valid) {
                base = s.coordinate;
                course = s.course;
                speed = s.speed;
                moving = !s.finished && s.speed > 0.05;
            }
            // An unreadable or too-short route falls through to the static
            // coordinate rather than producing nothing.
        }

        if (!CLLocationCoordinate2DIsValid(base)) return nil;

        // Real GPS never returns the identical coordinate twice.
        double jitter = config.jitterMetres;
        CLLocationCoordinate2D coord = base;
        if (jitter > 0.0) {
            coord = GSOffsetMetres(base, gs_gaussian(0.0, jitter), gs_gaussian(0.0, jitter));
        }
        if (!CLLocationCoordinate2DIsValid(coord)) coord = base;

        os_unfair_lock_lock(&_lock);

        // Accuracy wanders as a random walk rather than jumping around
        // uniformly, which is how a real receiver behaves as its solution
        // firms up or degrades.
        _hAcc = gs_clamp(_hAcc + gs_gaussian(0.0, 1.2), 5.0, 65.0);
        _vAcc = gs_clamp(_vAcc + gs_gaussian(0.0, 0.4), 3.0, 10.0);
        double hAcc = _hAcc;
        double vAcc = _vAcc;

        CLLocationSourceInformation *sourceInfo = [self sourceInfoForMode:config.sourceInfoMode];
        os_unfair_lock_unlock(&_lock);

        if (!moving) {
            // Stationary: a receiver reports a small non-zero speed and no
            // meaningful course.
            speed = gs_clamp(fabs(gs_gaussian(0.0, 0.08)), 0.0, 0.4);
            course = -1.0;
        }

        double speedAcc = gs_clamp(gs_gaussian(moving ? 0.9 : 0.6, 0.25), 0.2, 3.0);
        double courseAcc = (course >= 0.0)
            ? gs_clamp(gs_gaussian(12.0, 5.0), 3.0, 40.0)
            : -1.0;

        // Altitude noise of about half a metre; a barometric-aided fix is
        // quiet but not frozen.
        double altitude = config.altitude + gs_gaussian(0.0, 0.5);

        CLLocation *loc = gs_locationWithSourceInfo(coord, altitude, hAcc, vAcc,
                                                    course, courseAcc, speed, speedAcc,
                                                    now, sourceInfo);
        return loc;
    } @catch (NSException *e) {
        GSLog(@"factory: exception building location: %@", e);
        return nil;
    }
}

@end

#import "GSRouteEngine.h"
#import "GSCommon.h"
#import <os/lock.h>

static const double kEarthRadiusM = 6371008.8;
static const double kMetresPerDegreeLat = 111320.0;

double GSMetresBetween(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    double lat1 = a.latitude * M_PI / 180.0;
    double lat2 = b.latitude * M_PI / 180.0;
    double dLat = lat2 - lat1;
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double s = sin(dLat / 2.0) * sin(dLat / 2.0) +
               cos(lat1) * cos(lat2) * sin(dLon / 2.0) * sin(dLon / 2.0);
    return 2.0 * kEarthRadiusM * asin(fmin(1.0, sqrt(s)));
}

double GSInitialBearing(CLLocationCoordinate2D a, CLLocationCoordinate2D b) {
    double lat1 = a.latitude * M_PI / 180.0;
    double lat2 = b.latitude * M_PI / 180.0;
    double dLon = (b.longitude - a.longitude) * M_PI / 180.0;
    double y = sin(dLon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double deg = atan2(y, x) * 180.0 / M_PI;
    return fmod(deg + 360.0, 360.0);
}

// Metres -> degrees. cos(lat) collapses at the poles, so clamp it: at 89.9 deg
// the guard caps a 1 m east offset at about 0.0005 deg of longitude instead of
// letting it run away.
CLLocationCoordinate2D GSOffsetMetres(CLLocationCoordinate2D c, double dNorth, double dEast) {
    double latRad = c.latitude * M_PI / 180.0;
    double cosLat = fmax(0.01, fabs(cos(latRad)));
    CLLocationCoordinate2D out;
    out.latitude = c.latitude + dNorth / kMetresPerDegreeLat;
    out.longitude = c.longitude + dEast / (kMetresPerDegreeLat * cosLat);
    if (out.latitude > 90.0) out.latitude = 90.0;
    if (out.latitude < -90.0) out.latitude = -90.0;
    if (out.longitude > 180.0) out.longitude -= 360.0;
    if (out.longitude < -180.0) out.longitude += 360.0;
    return out;
}

// Shortest signed angular difference from a to b, in degrees.
static double gs_angleDelta(double a, double b) {
    return fmod(b - a + 540.0, 360.0) - 180.0;
}

#pragma mark - GPX parsing

// Collects <trkpt>, <rtept> and <wpt> lat/lon attributes in document order.
// NSXMLParser is enough; the brief rules out pulling in a dependency.
@interface GSGPXCollector : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSValue *> *points;
@end

@implementation GSGPXCollector

- (instancetype)init {
    if ((self = [super init])) _points = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary<NSString *, NSString *> *)attrs {
    NSString *name = elementName.lowercaseString;
    if (![name isEqualToString:@"trkpt"] &&
        ![name isEqualToString:@"rtept"] &&
        ![name isEqualToString:@"wpt"]) {
        return;
    }
    id lat = attrs[@"lat"] ?: attrs[@"Lat"];
    id lon = attrs[@"lon"] ?: attrs[@"Lon"];
    if (![lat isKindOfClass:[NSString class]] || ![lon isKindOfClass:[NSString class]]) return;

    CLLocationCoordinate2D c = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
    if (!CLLocationCoordinate2DIsValid(c)) return;
    [self.points addObject:[NSValue valueWithBytes:&c objCType:@encode(CLLocationCoordinate2D)]];
}

@end

#pragma mark - Engine

@implementation GSRouteEngine {
    os_unfair_lock _lock;

    NSString *_loadedPath;
    uint64_t _loadedGeneration;

    CLLocationCoordinate2D *_points;   // heap array, _count entries
    double *_cumulative;               // heap array, _count entries, metres from start
    NSUInteger _count;
    double _totalLength;

    double _cursor;                    // metres along the polyline
    double _direction;                 // +1 forward, -1 after a reverse
    NSDate *_lastTick;
    BOOL _finished;
    double _lastCourse;
}

+ (instancetype)shared {
    static GSRouteEngine *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[GSRouteEngine alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _direction = 1.0;
        _lastCourse = -1.0;
        _loadedGeneration = UINT64_MAX;
    }
    return self;
}

- (void)dealloc {
    free(_points);
    free(_cumulative);
}

+ (NSArray<NSValue *> *)coordinatesFromFile:(NSString *)path {
    if (path.length == 0) return nil;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        GSLog(@"route: cannot read %@", path);
        return nil;
    }

    // A .plist route is an array of {Latitude, Longitude} dictionaries. The
    // key name in the brief (RoutePlistPath) predates GPX support, so both
    // shapes are accepted and the key keeps its meaning either way.
    if ([path.pathExtension.lowercaseString isEqualToString:@"plist"]) {
        NSArray *arr = [NSArray arrayWithContentsOfFile:path];
        if (![arr isKindOfClass:[NSArray class]]) return nil;
        NSMutableArray<NSValue *> *out = [NSMutableArray array];
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            id lat = d[@"Latitude"] ?: d[@"lat"];
            id lon = d[@"Longitude"] ?: d[@"lon"];
            if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) continue;
            CLLocationCoordinate2D c = CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]);
            if (!CLLocationCoordinate2DIsValid(c)) continue;
            [out addObject:[NSValue valueWithBytes:&c objCType:@encode(CLLocationCoordinate2D)]];
        }
        return out.count ? out : nil;
    }

    GSGPXCollector *collector = [[GSGPXCollector alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = collector;
    if (![parser parse]) {
        // A partial parse is still usable if it produced a polyline.
        GSLog(@"route: GPX parse ended early for %@: %@", path, parser.parserError);
    }
    return collector.points.count ? collector.points : nil;
}

// Caller must hold _lock.
- (void)loadRouteAtPath:(NSString *)path generation:(uint64_t)generation {
    free(_points); _points = NULL;
    free(_cumulative); _cumulative = NULL;
    _count = 0;
    _totalLength = 0.0;
    _cursor = 0.0;
    _direction = 1.0;
    _finished = NO;
    _lastTick = nil;
    _lastCourse = -1.0;
    _loadedPath = [path copy];
    _loadedGeneration = generation;

    NSArray<NSValue *> *coords = [GSRouteEngine coordinatesFromFile:path];
    if (coords.count < 2) {
        GSLog(@"route: %@ yielded %lu usable points; need at least 2",
              path, (unsigned long)coords.count);
        return;
    }

    NSUInteger count = coords.count;
    CLLocationCoordinate2D *points = calloc(count, sizeof(CLLocationCoordinate2D));
    double *cumulative = calloc(count, sizeof(double));
    if (!points || !cumulative) {
        free(points);
        free(cumulative);
        return;
    }

    for (NSUInteger i = 0; i < count; i++) {
        [coords[i] getValue:&points[i]];
    }
    for (NSUInteger i = 1; i < count; i++) {
        cumulative[i] = cumulative[i - 1] + GSMetresBetween(points[i - 1], points[i]);
    }

    _points = points;
    _cumulative = cumulative;
    _count = count;
    _totalLength = cumulative[count - 1];

    GSLog(@"route: loaded %lu points, %.1f m from %@",
          (unsigned long)_count, _totalLength, path.lastPathComponent);
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    _loadedGeneration = UINT64_MAX;
    _loadedPath = nil;
    os_unfair_lock_unlock(&_lock);
}

// Caller must hold _lock. Returns i such that the cursor lies in segment [i, i+1].
- (NSUInteger)segmentIndexForDistance:(double)d {
    NSUInteger lo = 0, hi = _count - 1;
    while (lo + 1 < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (_cumulative[mid] <= d) lo = mid; else hi = mid;
    }
    return lo;
}

// Caller must hold _lock. How sharp is the turn at the vertex ahead, 0..1.
- (double)turnSharpnessNearDistance:(double)d lookahead:(double)lookahead {
    if (_count < 3) return 0.0;
    NSUInteger i = [self segmentIndexForDistance:d];
    NSUInteger vertex = (_direction > 0) ? i + 1 : i;
    if (vertex == 0 || vertex + 1 >= _count) return 0.0;

    double distanceToVertex = fabs(_cumulative[vertex] - d);
    if (distanceToVertex > lookahead) return 0.0;

    double incoming = GSInitialBearing(_points[vertex - 1], _points[vertex]);
    double outgoing = GSInitialBearing(_points[vertex], _points[vertex + 1]);
    double turn = fabs(gs_angleDelta(incoming, outgoing));      // 0..180
    double proximity = 1.0 - (distanceToVertex / lookahead);    // 0..1
    return fmin(1.0, (turn / 180.0) * proximity);
}

- (GSRouteSample)sampleForConfig:(GSConfig *)config atDate:(NSDate *)now {
    GSRouteSample sample = {0};
    sample.coordinate = kCLLocationCoordinate2DInvalid;
    sample.course = -1.0;
    sample.speed = 0.0;
    sample.valid = NO;
    sample.finished = NO;

    if (config.mode != GSModeRoute || config.routePath.length == 0) return sample;

    os_unfair_lock_lock(&_lock);
    @try {
        BOOL needsLoad = (_loadedGeneration != config.generation) ||
                         ![_loadedPath isEqualToString:config.routePath];
        if (needsLoad) {
            [self loadRouteAtPath:config.routePath generation:config.generation];
        }
        if (_count < 2 || _totalLength <= 0.0) {
            os_unfair_lock_unlock(&_lock);
            return sample;
        }

        // Advance the cursor by however long we were away, clamped so an app
        // that was suspended does not teleport across the route on resume.
        double dt = 0.0;
        if (_lastTick) {
            dt = fmax(0.0, [now timeIntervalSinceDate:_lastTick]);
            dt = fmin(dt, 5.0);
        }
        _lastTick = now;

        double base = config.routeSpeedMps;
        // +/-10% so the speed channel is not suspiciously constant.
        double wobble = 0.9 + 0.2 * ((double)arc4random_uniform(10000) / 10000.0);
        double sharpness = [self turnSharpnessNearDistance:_cursor lookahead:20.0];
        // Ease into and out of sharp turns rather than pivoting at full speed.
        double speed = base * wobble * (1.0 - 0.6 * sharpness);

        if (!_finished) _cursor += speed * dt * _direction;

        if (_cursor >= _totalLength || _cursor < 0.0) {
            switch (config.routeEndBehavior) {
                case GSRouteEndLoop:
                    _cursor = fmod(fmod(_cursor, _totalLength) + _totalLength, _totalLength);
                    _direction = 1.0;
                    break;
                case GSRouteEndReverse:
                    if (_cursor >= _totalLength) {
                        _cursor = fmax(0.0, 2.0 * _totalLength - _cursor);
                        _direction = -1.0;
                    } else {
                        _cursor = fmin(_totalLength, -_cursor);
                        _direction = 1.0;
                    }
                    break;
                case GSRouteEndStop:
                    _cursor = fmin(fmax(_cursor, 0.0), _totalLength);
                    _finished = YES;
                    speed = 0.0;
                    break;
            }
        }

        NSUInteger i = [self segmentIndexForDistance:_cursor];
        double segStart = _cumulative[i];
        double segLength = _cumulative[i + 1] - segStart;
        double t = (segLength > 0.0) ? ((_cursor - segStart) / segLength) : 0.0;
        t = fmin(1.0, fmax(0.0, t));

        CLLocationCoordinate2D a = _points[i];
        CLLocationCoordinate2D b = _points[i + 1];
        sample.coordinate = CLLocationCoordinate2DMake(a.latitude + (b.latitude - a.latitude) * t,
                                                       a.longitude + (b.longitude - a.longitude) * t);

        double segBearing = GSInitialBearing(a, b);
        if (_direction < 0) segBearing = fmod(segBearing + 180.0, 360.0);

        // Blend the heading towards the segment bearing instead of snapping to
        // it, so crossing a vertex is not an instant course discontinuity.
        if (_lastCourse < 0.0) {
            _lastCourse = segBearing;
        } else {
            double blend = fmin(1.0, fmax(0.15, dt * 2.0));
            _lastCourse = fmod(_lastCourse + gs_angleDelta(_lastCourse, segBearing) * blend + 360.0, 360.0);
        }

        sample.speed = fmax(0.0, speed);
        sample.course = _finished ? -1.0 : _lastCourse;
        sample.finished = _finished;
        sample.valid = YES;
    } @catch (NSException *e) {
        GSLog(@"route: exception during sample: %@", e);
        sample.valid = NO;
    }
    os_unfair_lock_unlock(&_lock);
    return sample;
}

@end

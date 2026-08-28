// GSRouteEngine.h - GPX polyline loading and time-based interpolation.
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "GSConfig.h"

typedef struct {
    CLLocationCoordinate2D coordinate;
    CLLocationDirection course;   // -1 when not meaningful
    CLLocationSpeed speed;        // m/s, >= 0
    BOOL valid;                   // NO means the caller should fall back to static
    BOOL finished;                // route ran to its end and RouteEndBehavior is stop
} GSRouteSample;

@interface GSRouteEngine : NSObject

+ (instancetype)shared;

// Loads (and caches) the route named by the config, advances the distance
// cursor by the time elapsed since the previous call, and returns the
// interpolated position. Thread safe.
- (GSRouteSample)sampleForConfig:(GSConfig *)config atDate:(NSDate *)now;

// Drops cached route state. Called when the config generation changes.
- (void)reset;

// Exposed for the CLI/tests: parse a GPX or plist route file into coordinates.
+ (NSArray<NSValue *> *)coordinatesFromFile:(NSString *)path;

@end

// Geodesic helpers, shared with the location factory.
double GSMetresBetween(CLLocationCoordinate2D a, CLLocationCoordinate2D b);
double GSInitialBearing(CLLocationCoordinate2D a, CLLocationCoordinate2D b);
CLLocationCoordinate2D GSOffsetMetres(CLLocationCoordinate2D c, double dNorth, double dEast);

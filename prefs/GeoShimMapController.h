// A full-screen MapKit picker for the spoofed coordinate. Pushed from the
// GeoShim Settings page. Centres on the currently saved coordinate, lets the
// user pan a crosshair over the target, and on Save writes Latitude/Longitude
// back to the xyz.regulad.geoshim domain and posts the reload notification so
// locationd (and any covered app on its next fix) picks it up.
#import <UIKit/UIKit.h>

@interface GeoShimMapController : UIViewController
@end

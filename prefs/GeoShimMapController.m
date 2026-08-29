#import "GeoShimMapController.h"
#import <MapKit/MapKit.h>
#import <notify.h>

// Settings.app reads and writes our settings-bundle domain through cfprefsd, so
// CFPreferences here lands in the same /var/mobile plist the CLI writes and the
// daemon reads. Posting the Darwin notification triggers the live reload.
static NSString *const kGSDomain = @"xyz.regulad.geoshim";
static NSString *const kGSNotify = @"xyz.regulad.geoshim/prefsChanged";

@interface GeoShimMapController () <MKMapViewDelegate>
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) UILabel *coordLabel;
@end

@implementation GeoShimMapController

- (id)gs_read:(NSString *)key {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kGSDomain);
    return v ? (__bridge_transfer id)v : nil;
}

- (CLLocationCoordinate2D)savedCoordinate {
    id la = [self gs_read:@"Latitude"];
    id lo = [self gs_read:@"Longitude"];
    if ([la isKindOfClass:[NSNumber class]] && [lo isKindOfClass:[NSNumber class]]) {
        CLLocationCoordinate2D c = CLLocationCoordinate2DMake([la doubleValue], [lo doubleValue]);
        if (CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0)) return c;
    }
    // No saved coordinate: fall back to a neutral world view.
    return CLLocationCoordinate2DMake(37.3349, -122.0090);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Set Location";
    if (@available(iOS 13.0, *)) self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    self.mapView.delegate = self;
    self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) self.mapView.showsUserLocation = NO;
    [self.view addSubview:self.mapView];

    // A fixed crosshair pinned to the map centre: the user pans the map under it
    // rather than dragging a pin, which is simpler and never loses the target.
    UIImageView *cross = [[UIImageView alloc] init];
    cross.translatesAutoresizingMaskIntoConstraints = NO;
    cross.contentMode = UIViewContentModeCenter;
    if (@available(iOS 13.0, *)) {
        cross.image = [UIImage systemImageNamed:@"plus.viewfinder"];
        cross.tintColor = UIColor.systemRedColor;
        cross.preferredSymbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightBold];
    }
    [self.view addSubview:cross];

    // A translucent bar showing the live centre coordinate.
    UIVisualEffectView *bar = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    self.coordLabel = [[UILabel alloc] init];
    self.coordLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.coordLabel.textAlignment = NSTextAlignmentCenter;
    self.coordLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    self.coordLabel.numberOfLines = 1;
    [bar.contentView addSubview:self.coordLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.mapView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.mapView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [cross.centerXAnchor constraintEqualToAnchor:self.mapView.centerXAnchor],
        [cross.centerYAnchor constraintEqualToAnchor:self.mapView.centerYAnchor],

        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [bar.heightAnchor constraintEqualToConstant:44],

        [self.coordLabel.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor constant:12],
        [self.coordLabel.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor constant:-12],
        [self.coordLabel.centerYAnchor constraintEqualToAnchor:bar.contentView.centerYAnchor],
    ]];
    bar.layer.cornerRadius = 12;
    bar.clipsToBounds = YES;

    CLLocationCoordinate2D c = [self savedCoordinate];
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 3000, 3000) animated:NO];
    [self updateLabel];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self action:@selector(save)];
}

- (void)updateLabel {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    self.coordLabel.text = [NSString stringWithFormat:@"%.5f,  %.5f", c.latitude, c.longitude];
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    [self updateLabel];
}

- (void)save {
    CLLocationCoordinate2D c = self.mapView.centerCoordinate;
    if (!CLLocationCoordinate2DIsValid(c)) return;

    CFStringRef domain = (__bridge CFStringRef)kGSDomain;
    CFPreferencesSetAppValue(CFSTR("Latitude"), (__bridge CFNumberRef)@(c.latitude), domain);
    CFPreferencesSetAppValue(CFSTR("Longitude"), (__bridge CFNumberRef)@(c.longitude), domain);
    // Setting a coordinate implies static targeting; leave Enabled to the switch.
    CFPreferencesSetAppValue(CFSTR("Mode"), CFSTR("static"), domain);
    CFPreferencesAppSynchronize(domain);
    notify_post(kGSNotify.UTF8String);

    [self.navigationController popViewControllerAnimated:YES];
}

@end

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GeoShimPrefs
GeoShimPrefs_FILES = GeoShimRootListController.m GeoShimMapController.m
GeoShimPrefs_INSTALL_PATH = /Library/PreferenceBundles
GeoShimPrefs_CFLAGS = -fobjc-arc -I..
GeoShimPrefs_FRAMEWORKS = UIKit MapKit CoreLocation
GeoShimPrefs_PRIVATE_FRAMEWORKS = Preferences
# AltList provides the app picker (ATLApplicationListMultiSelectionController).
# roothide bundles it in theos; if linking fails, run AltList's
# install_to_theos.sh once. Runtime dependency declared in ../control.
GeoShimPrefs_EXTRA_FRAMEWORKS = AltList

include $(THEOS_MAKE_PATH)/bundle.mk

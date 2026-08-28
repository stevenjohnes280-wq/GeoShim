export THEOS_PACKAGE_SCHEME = roothide

TARGET = iphone:latest:15.0
ARCHS = arm64

# Restart the daemon on install. Killing locationd is disruptive but it
# relaunches immediately; fine for iterate-install-check.
INSTALL_TARGET_PROCESSES = locationd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GeoShim
GeoShim_FILES = Tweak.x GSConfig.m GSLocationFactory.m GSRouteEngine.m
GeoShim_CFLAGS = -fobjc-arc -Wall
GeoShim_FRAMEWORKS = CoreLocation Foundation

# The identifier lives in one place. Paths are resolved at runtime from the
# binary's own location (GSPaths.m), so there is no compile-time prefix and no
# libroothide dependency.
GeoShim_CFLAGS += -DGS_IDENTIFIER='@"xyz.regulad.geoshim"'

# Debug logging is off unless you ask for it: make GEOSHIM_DEBUG=1
ifeq ($(GEOSHIM_DEBUG),1)
GeoShim_CFLAGS += -DGEOSHIM_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += cli
include $(THEOS_MAKE_PATH)/aggregate.mk

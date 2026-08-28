TARGET = iphone:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = geoshim
geoshim_FILES = main.m ../GSRouteEngine.m ../GSConfig.m
geoshim_CFLAGS = -fobjc-arc -Wall -I..
geoshim_FRAMEWORKS = Foundation CoreLocation
geoshim_INSTALL_PATH = /usr/local/bin

# roothide requires these entitlements or the binary runs sandboxed/containerized
# (entitlements.md): its prefs writes would land in a private container and dyld
# is denied access to jbroot libraries. ldid -S embeds them.
geoshim_CODESIGN_FLAGS = -Sentitlements.plist

# Same identifier as the dylib. No prefix define: jbroot() resolves the
# preferences and route paths at runtime, so the CLI and the dylib agree.
geoshim_CFLAGS += -DGS_IDENTIFIER='@"xyz.regulad.geoshim"'

ifeq ($(GEOSHIM_DEBUG),1)
geoshim_CFLAGS += -DGEOSHIM_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tool.mk

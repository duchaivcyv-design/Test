export ARCHS = arm64
export TARGET = iphone:clang:12.4:11.0
INSTALL_TARGET_PROCESSES = SpringBoard
SUBPROJECTS += wave12prefs

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Wave12
Wave12_FILES = Tweak.m LockStyle.m TabBar.m
Wave12_FRAMEWORKS = UIKit QuartzCore CoreGraphics
Wave12_CFLAGS = -fobjc-arc -Os -fvisibility=hidden -Wno-deprecated-declarations -Wno-error -Wno-deprecated-module-dot-map

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

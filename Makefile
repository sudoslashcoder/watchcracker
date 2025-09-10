ARCHS = arm64
TARGET := iphone:clang:latest:16.5
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = watchcracker

watchcracker_FILES = Tweak.xm
watchcracker_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

TARGET := iphone:clang:latest:7.0
INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = watchcracker

watchcracker_FILES = Tweak.x
watchcracker_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

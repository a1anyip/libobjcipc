export THEOS_DEVICE_IP=127.0.0.1
export THEOS_DEVICE_PORT=2222

export TARGET = :clang
export ARCHS = armv7 arm64
export ADDITIONAL_OBJCFLAGS = -fvisibility=default -fvisibility-inlines-hidden -fno-objc-arc -O2

LIBRARY_NAME = libobjcipc
libobjcipc_FILES = IPC.m Connection.m Message.m
libobjcipc_FRAMEWORKS = CoreFoundation Foundation UIKit
libobjcipc_INSTALL_PATH = /usr/lib/
libobjcipc_LIBRARIES = substrate

SUBPROJECTS = substrate

include theos/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 backboardd"
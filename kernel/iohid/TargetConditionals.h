/*
 * Ours (MIT), not Apple's file. The published IOKit/hid headers (the macOS SDK's Kernel.framework) ask for
 * <TargetConditionals.h>, which a kernel build does not have; they test only TARGET_OS_OSX (IOHIDDevice.h) and
 * TARGET_OS_DRIVERKIT (IOHIDDeviceTypes.h, IOHIDDescriptorParser.h). The target is the macOS kernel. Used only by
 * iokit/Native/IcelandHid/NativeIcelandHid.cpp through NATIVE_IOHID_INCLUDE (kernel/ci-build.sh).
 */
#ifndef ICELAND_IOHID_TARGETCONDITIONALS_H
#define ICELAND_IOHID_TARGETCONDITIONALS_H
#ifndef TARGET_OS_MAC
#define TARGET_OS_MAC 1
#endif
#ifndef TARGET_OS_OSX
#define TARGET_OS_OSX 1
#endif
#ifndef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 0
#endif
#ifndef TARGET_OS_DRIVERKIT
#define TARGET_OS_DRIVERKIT 0
#endif
#endif

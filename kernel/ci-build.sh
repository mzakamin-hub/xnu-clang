#!/usr/bin/env bash
# Compile our xnu kernel with Xcode's clang on the macOS runner (workflow xnu-kernel.yml).
#
#   kernel/ci-build.sh <series> <artifact-directory>
#
# 1. kernel/rule-gate.py checks kernel/series/<series>.patch; nothing is fetched or applied before it passes.
# 2. Apple's xnu and the open-source pieces of kernel/pins.json are fetched by exact commit (and checked).
# 3. The kernel SDK is Xcode's iPhoneOS SDK (as links) plus usr/local: availability.pl, the firehose headers, and the
#    firehose and pthread kernel archives compiled here from their open source, exactly as our clang-22 build's kernel
#    SDK is made (hakios-arm64e-iceland xnu-deps/setup.sh stage1_darwin + stage2), with Xcode's clang instead.
# 4. make builds the kernel with our make line (hakios base/xnu-build.sh, ICELAND_OS=macos): only the compiler and the
#    tools are Xcode's. LD is kernel/record-link.sh: it records the kernel link and runs it, and that link stops on the
#    symbols of the archives that stay on the project machine (corecrypto, source storage): expected.
# 5. kernel/collect.py checks that the link stopped for that reason only and packs the objects.
set -euo pipefail
series="${1:?usage: ci-build.sh <series> <artifact-directory>}"
artifacts="${2:?usage: ci-build.sh <series> <artifact-directory>}"
case "$series" in *[!a-z0-9-]*|'') echo "::error::series: lower-case letters, digits and dashes"; exit 1 ;; esac
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch="$here/series/$series.patch"
[ -f "$patch" ] || { echo "::error::no kernel/series/$series.patch"; exit 1; }
: "${DEVELOPER_DIR:?select-xcode.sh must run first}"
# read the whole output first: `xcodebuild -version | head -1` aborts xcodebuild (SIGPIPE -> NSException) under pipefail
xv="$(xcodebuild -version)"; xv="${xv%%$'\n'*}"
case "$xv" in "Xcode 26.6"|"Xcode 26.6."*) ;; *) echo "::error::the build is pinned to Xcode 26.6 (sheng's): $xv"; exit 1 ;; esac
W="${RUNNER_TEMP:-/tmp}/xnu-k"
S="$W/src"                      # fetched sources (cached between runs: open source only)
X="$W/xnu"                      # the patched tree (never cached)
K="$W/iPhoneOS-xnu.sdk"         # the kernel SDK
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$S" "$artifacts"
log() { echo "== $(date -u +%H:%M:%S) $*"; }
pin() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sources"][sys.argv[2]][sys.argv[3]])' "$here/pins.json" "$1" "$2"; }
val() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["owner_build_values"][sys.argv[2]])' "$here/pins.json" "$1"; }

log "1. rule gate on $series.patch ($(shasum -a 256 "$patch" | cut -c1-16))"
python3 -I "$here/rule-gate.py" "$patch"

# fetch NAME: one commit of a pinned repository, without its history; a cached copy is used only at the same commit
fetch() {
    local dir="$S/$1" url commit
    url=$(pin "$1" git); commit=$(pin "$1" commit)
    if [ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" != "$commit" ]; then
        rm -rf "$dir"; git init -q "$dir"; git -C "$dir" remote add origin "$url"
        git -C "$dir" fetch -q --depth 1 origin "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    fi
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "::error::$1 is not at $commit"; exit 1; }
    [ -z "$(git -C "$dir" status --porcelain)" ] || { echo "::error::$1 checkout is not clean"; exit 1; }
    echo "   $1 $(pin "$1" tag) $commit"
}
log "2. public sources"
for name in xnu AvailabilityVersions libdispatch libpthread IONetworkingFamily; do fetch "$name"; done
rm -rf "$X"; cp -R "$S/xnu" "$X"
git -C "$X" apply --check "$patch"
git -C "$X" apply "$patch"
log "   series applied: $(git -C "$X" status --porcelain | wc -l | tr -d ' ') paths changed"

log "3. kernel SDK: Xcode's iPhoneOS SDK + usr/local (open source)"
xsdk=$(xcrun --sdk iphoneos --show-sdk-path)
msdk=$(xcrun --sdk macosx --show-sdk-path)
rm -rf "$K"; mkdir -p "$K/usr"
for f in "$xsdk"/*; do [ "$(basename "$f")" = usr ] || ln -s "$f" "$K/"; done
for f in "$xsdk"/usr/*; do [ "$(basename "$f")" = local ] || ln -s "$f" "$K/usr/"; done
L="$K/usr/local"
mkdir -p "$L/include/kernel/os" "$L/include/os" "$L/lib/kernel/platform" "$L/libexec"
install -m 755 "$S/AvailabilityVersions/availability.pl" "$L/libexec/availability.pl"
{ unifdef -DOS_FIREHOSE_SPI=1 -DKERNEL=1 "$S/libdispatch/os/firehose_buffer_private.h" || [ $? -eq 1 ]; } > "$L/include/kernel/os/firehose_buffer_private.h"
cp "$S/libdispatch/src/firehose/firehose_types.defs" "$L/include/kernel/os/firehose_types.defs"

# Build inputs outside the tree that our makefiles name (iokit/conf/Makefile.template): IONetworkingFamily-188's headers
# and the macOS SDK's own IOKit/hid headers, both after the kernel's own, as on the project machine (build/ionet, build/iohid).
I="$W/inc"; rm -rf "$I"; mkdir -p "$I/ionet/IOKit" "$I/iohid/IOKit"
ln -s "$S/IONetworkingFamily" "$I/ionet/IOKit/network"
# The project machine's hid headers are MacOSX26.1.sdk's (build/iohid/SOURCE.txt). Newer SDKs' IOHIDKeys.h-family headers
# include IOKit/hid/IOHIDPrivateKeys.h, which no SDK ships (run 45633752167), so take 26.1's from the runner's Xcode 26.1
# (headers only: the compiler stays Xcode 26.6) and fall back to the selected SDK when that Xcode is absent.
hsdk=$(ls -d /Applications/Xcode_26.1*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.1.sdk 2>/dev/null | sed -n 1p)
kh="${hsdk:-$msdk}/System/Library/Frameworks/Kernel.framework/Versions/A/Headers"
log "   hid headers from ${hsdk:-$msdk}"
for d in hid hidsystem graphics; do ln -s "$kh/IOKit/$d" "$I/iohid/IOKit/$d"; done
ln -s "$kh/HIDDriverKit" "$I/iohid/HIDDriverKit"
cp "$here/iohid/TargetConditionals.h" "$I/iohid/TargetConditionals.h"

# The owner values of the build (macos-qemu.config), with the Data volume UUID as its placeholder.
OH="$W/owner-data-volume.h"
printf '#define XNU_OWNER_DATA_VOLUME_UUID "%s"\n#define XNU_OWNER_CACHE_VOLUME_UUID "%s"\n#define XNU_OWNER_ROOT_VOLUME_UUID "%s"\n' \
    "$(val XNU_OWNER_DATA_VOLUME_UUID)" "$(val XNU_OWNER_CACHE_VOLUME_UUID)" "$(val XNU_OWNER_ROOT_VOLUME_UUID)" > "$OH"

DT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deployment_target"])' "$here/pins.json")
# The assembled SDK is not one xcodebuild knows, so `xcrun -sdk <it> -show-sdk-version` fails (run 45627389140:
# "xcodebuild: error: SDK ... cannot be located"). makedefs/MakeInc.cmd asks only when SDKROOT_RESOLVED / SDKVERSION /
# PLATFORM are unset, so all three are given: the path itself, and the version our clang-22 build's xcrun answers for its
# iPhoneOS16.5.xnu.sdk (xnu-deps host/bin/xcrun: XNU_SDK_VERSION, 16.5 = the deployment target). SDKVERSION is used
# otherwise only by the default DEPLOYMENT_TARGET_FLAGS (replaced below) and the DriverKit/Exclave cohort names (unused).
#
# XNU_NO_TYPE_BUILTINS: our tree tests it (libkern/c++/OSData.h:970, osfmk/kern/kalloc.h:923; xnu-macos 629045ce) and
# the clang-22 build gets it from the force-included xnu-deps hostinc/xnu_clang_compat.h: 1 where the compiler lacks
# __builtin_xnu_type_signature (upstream clang: stubs, every type "mixed"), 0 where it has it ("Apple's clang ... has the
# builtins; OSData.h still tests the macro"). Xcode's clang has them, so 0: the compat header's own Apple-clang value,
# and Apple's unmodified static_assert / kalloc_type path, as sheng's Xcode 26.6 kernel compiles it. In
# DEPLOYMENT_TARGET_FLAGS because that reaches C, assembly and C++ alike (MakeInc.rule:521, 543).
MAKEARGV=(make -C "$X" SDKROOT="$K" SDKROOT_RESOLVED="$K" SDKVERSION="$DT" PLATFORM=iPhoneOS
  PLATFORMPATH="$(xcrun --sdk iphoneos --show-sdk-platform-path)"
  ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=BCM2837 KERNEL_CONFIGS=DEVELOPMENT ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64e
  RC_DARWIN_KERNEL_VERSION=12377.121.6 BUILD_WERROR=0 BUILD_LTO=0 DO_CTFMERGE=0 BUILD_DSYM=0 LOGCOLORS=n MAKEJOBS=-j"$JOBS"
  "DEPLOYMENT_TARGET_FLAGS=-miphoneos-version-min=$DT -DXNU_TARGET_OS_OSX -DPEXPERT_NO_3X_IMAGES=1 -DXNU_PTRAUTH_SIGNED_DATA_PTRS=1 -DXNU_NO_TYPE_BUILTINS=0"
  "CFLAGS_EXTRA=-DXNU_SOURCE_CORECRYPTO14=1" "prng_random.o_CFLAGS_ADD="
  "ubc_subr.o_CFLAGS_ADD=-DXNU_NATIVE_CS_HASH_CACHE=1"
  "bsd_init.o_CFLAGS_ADD=-DXNU_VERIFIED_ROOT_PROBE=$(val XNU_VERIFIED_ROOT_PROBE) -DXNU_SOURCE_STORAGE=$(val XNU_SOURCE_STORAGE) -DXNU_OWNER_ROOT_AUDIT=$(val XNU_OWNER_ROOT_AUDIT) -DXNU_OWNER_ROOT_TRUST=$(val XNU_OWNER_ROOT_TRUST)"
  "vfs_conf.o_CFLAGS_ADD=-DMOCKFS=$(val XNU_SOURCE_MOCKFS) -DAPFS=$(val XNU_SOURCE_INTREE_APFS)"
  "kern_exec.o_CFLAGS_ADD=-DXNU_OWNER_CACHE_MOUNT=$(val XNU_OWNER_CACHE_MOUNT) -DXNU_OWNER_UNION_SYSTEMOS=$(val XNU_OWNER_UNION_SYSTEMOS) -DXNU_OWNER_CACHE_STARTUP=$(val XNU_OWNER_CACHE_STARTUP) -DXNU_OWNER_BOOT_MANIFEST=$(val XNU_OWNER_BOOT_MANIFEST) -DXNU_NATIVE_RAM_BLOCK=$(val XNU_NATIVE_RAM_BLOCK) -DXNU_OWNER_DATA_MOUNT=$(val XNU_OWNER_DATA_MOUNT) -include $OH"
  "IOKitBSDInit.cpo_CFLAGS_ADD=-DXNU_OWNER_BOOT_MANIFEST=$(val XNU_OWNER_BOOT_MANIFEST)"
  NATIVE_IONET_INCLUDE="$I/ionet" NATIVE_IOHID_INCLUDE="$I/iohid")
# iokit/conf/Makefile.template strips __DATA,__mod_init_func from the late objects with NATIVE_LATE_OBJCOPY (default
# llvm-objcopy-22, the project machine's name; run 45639993071: "command not found"). Any llvm-objcopy does this section
# removal: Xcode's if it ships one, else the runner image's Homebrew LLVM.
oc=$(xcrun --find llvm-objcopy 2>/dev/null || true)
[ -n "$oc" ] || oc=$(ls -d /opt/homebrew/opt/llvm*/bin/llvm-objcopy /usr/local/opt/llvm*/bin/llvm-objcopy 2>/dev/null | sort -V | sed -n '$p')
[ -n "$oc" ] || oc=$(command -v llvm-objcopy || true)
[ -n "$oc" ] || { echo "::error::no llvm-objcopy on the runner (NATIVE_LATE_OBJCOPY)"; exit 1; }
log "   NATIVE_LATE_OBJCOPY=$oc ($("$oc" --version 2>/dev/null | sed -n 2p))"
MAKEARGV+=(NATIVE_LATE_OBJCOPY="$oc")

log "4a. exported kernel headers"
"${MAKEARGV[@]}" exporthdrs > "$W/exporthdrs.log" 2>&1 || { tail -40 "$W/exporthdrs.log"; echo "::error::exporthdrs failed"; exit 1; }
E="$X/BUILD/obj/EXPORT_HDRS"

log "4b. libfirehose_kernel.a and libpthread_kext.a from open source, Xcode's clang"
KCC=(xcrun --sdk iphoneos clang -target arm64e-apple-ios"$DT" -c -Os -mkernel -nostdinc -fno-builtin
     -isystem "$(xcrun --sdk iphoneos clang -print-resource-dir)/include" -D__DARWIN_64_BIT_INO_T=1 -DARM64_BOARD_CONFIG_BCM2837
     -DKERNEL=1 -DKERNEL_PRIVATE=1 -DPRIVATE=1 -DXNU_NO_TYPE_BUILTINS=0
     -I"$E/osfmk" -I"$E/bsd" -I"$E/libkern" -I"$E/pexpert" -I"$E/iokit" -I"$E/security" -I"$X/EXTERNAL_HEADERS")
B="$W/libs"; rm -rf "$B"; mkdir -p "$B/inc"
"${KCC[@]}" -DXNU_KERNEL_PRIVATE=1 -DDISPATCH_USE_DTRACE=0 -DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 \
    -DOS_ATOMIC_CONFIG_STARVATION_FREE_ONLY=0 -DOS_FIREHOSE_SPI=1 \
    -I"$S/libdispatch" -I"$S/libdispatch/src" -I"$S/libdispatch/src/firehose" -I"$X/libkern/firehose" -I"$E/libkern/os" \
    -I"$L/include/kernel" -o "$B/firehose_buffer.o" "$S/libdispatch/src/firehose/firehose_buffer.c"
xcrun --sdk iphoneos libtool -static -o "$L/lib/kernel/libfirehose_kernel.a" "$B/firehose_buffer.o"
printf '#ifndef TARGET_OS_OSX\n#define TARGET_OS_OSX 1\n#endif\n#ifndef TARGET_OS_IPHONE\n#define TARGET_OS_IPHONE 0\n#endif\n#ifndef TARGET_OS_MAC\n#define TARGET_OS_MAC 1\n#endif\n' > "$B/inc/TargetConditionals.h"
for f in kern_init kern_support kern_synch; do
    "${KCC[@]}" -fno-common -Wno-int-conversion -D__PTHREAD_EXPOSE_INTERNALS__=1 -Dpthread_kern=pthread_kext_kern \
        -Dcurrent_uthread=pthread_kext_current_uthread -I"$B/inc" -I"$S/libpthread" -I"$S/libpthread/include" \
        -I"$S/libpthread/private" -o "$B/pthread_$f.o" "$S/libpthread/kern/$f.c"
done
xcrun --sdk iphoneos libtool -static -o "$L/lib/kernel/libpthread_kext.a" "$B"/pthread_kern_*.o
# -lcc_kext (MakeInc.def LD_KERNEL_LIBS) is in Apple's internal SDK only. This link is a record, not the product: Xcode's
# kext compiler runtime stands in when the toolchain has one, otherwise an empty archive, and any builtin left undefined
# is resolved by the project machine's -lcc_kext at the real link. Neither archive is uploaded (collect.py).
rt=$(find "$(xcrun --sdk iphoneos clang -print-resource-dir)/lib" -name 'libclang_rt.cc_kext*.a' 2>/dev/null | sort | sed -n 1p)
if [ -n "$rt" ]; then ln -sf "$rt" "$L/lib/kernel/libcc_kext.a"; echo "   -lcc_kext: $rt"
else printf '' | "${KCC[@]}" -x c -o "$B/empty.o" - && xcrun --sdk iphoneos libtool -static -o "$L/lib/kernel/libcc_kext.a" "$B/empty.o"; echo "   -lcc_kext: empty stand-in"; fi

log "4c. the kernel (make build; the link records itself and stops on the project machine's archives)"
export ICE_LINK_RECORD="$W/link-record.json"
rm -f "$ICE_LINK_RECORD"
start=$(date +%s)
set +e
# -k as our clang-22 build runs it (perf1 xnu-build-w.sh -j10 -k): one run reports every compile error, not the first.
"${MAKEARGV[@]}" -k LD="$here/record-link.sh" LD_KERNEL_ARCHIVES='$(LDFLAGS_KERNEL_SDK) -lfirehose_kernel -lpthread_kext' \
    build > "$W/build.log" 2>&1
status=$?
set -e
log "   make exit $status after $(( $(date +%s) - start )) s; $(grep -c ' error: ' "$W/build.log" || true) compiler error lines"
grep -n ' error: ' "$W/build.log" | grep -v 'linker command failed' | head -40 || true
if [ "$status" != 0 ]; then
  # run 45637097196: make exit 2 with no ' error: ' line. Show what else stopped it (make, tools, missing files).
  log "   make's own stops and other failures:"
  grep -n -a -E '\*\*\* |[Ee]rror [0-9]|fatal|command not found|No such file|not found|Undefined symbols|ld: |Killed|Abort' "$W/build.log" \
    | grep -v -E ' warning: ' | head -60 || true
  log "   last 40 lines of the build log:"
  tail -n 40 "$W/build.log" || true
fi

log "5. check and pack"
python3 -I "$here/collect.py" --xnu "$X" --record "$ICE_LINK_RECORD" --log "$W/build.log" --sdk-lib "$L/lib/kernel" \
    --pins "$here/pins.json" --series "$patch" --out "$artifacts"

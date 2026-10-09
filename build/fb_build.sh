#!/bin/bash
# Build NVRMFB.kext, the macOS framebuffer (IOFramebuffer over NVKMS heads), the same way accel_build.sh builds NVAccel.
#
#   build/fb_build.sh [src] [out]        (default: kexts/NVRMFB -> out/fb/NVRMFB.kext)
#
# Needs macOS with Xcode and NVIDIA's open-gpu-kernel-modules 610.57.04 at $OGKM (default ~/ogkm610) WITH its Darwin
# build outputs: src/nvidia/_out/Darwin_x86_64/compile_cmds.sh supplies RM's -D flags, which fix the layout of the RM
# structures the kext shares with NVRM. NVIDIA publishes a Linux build system only; see build/build.sh for what that means.
# This script mirrors accel_build.sh and is not exercised by the CI workflow (CI has no Darwin RM build).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${1:-$REPO/kexts/NVRMFB}; OUT=${2:-$REPO/out/fb}; OGKM=${OGKM:-$HOME/ogkm610}
command -v xcrun >/dev/null 2>&1 || { echo "STOP: xcrun not found; kexts need macOS with Xcode"; exit 2; }
[ -f "$SRC/fb/nvrm-fb.cpp" ] || { echo "STOP: no NVRMFB source at $SRC"; exit 2; }
NV="$OGKM/src/nvidia"; KMS="$OGKM/src/nvidia-modeset"
[ -f "$NV/_out/Darwin_x86_64/compile_cmds.sh" ] || { echo "STOP: $NV/_out/Darwin_x86_64/compile_cmds.sh is missing: the display kexts take RM's compile flags from a Darwin build of open-gpu-kernel-modules 610.57.04 (set OGKM; see build/build.sh)"; exit 2; }
mkdir -p "$OUT/NVRMFB.kext/Contents/MacOS"
SDK=$(xcrun --show-sdk-path); KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$NV/arch/nvalloc/common/inc/gsp"
  -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw" -I"$OGKM/src/common/inc"
  -I"$OGKM/src/common/shared/inc" -I"$NV/inc" -I"$NV/inc/os" -I"$NV/inc/kernel" -I"$NV/kernel/inc" -I"$NV/interface"
  -I"$OGKM/src/common/nvlink/interface" -I"$OGKM/src/common/inc/swref" -I"$OGKM/src/common/inc/swref/published"
  -I"$NV/inc/libraries" -I"$NV/src/libraries" -I"$NV/generated" -I"$NV/src/mm/uvm/interface"
  -I"$OGKM/src/common/uproc/os/libos-v2.0.0/include" -I"$OGKM/src/common/uproc/os/common/include"
  -I"$OGKM/src/common/inc/displayport" -I"$OGKM/src/common/nvlink/inband/interface" )
KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include" -I"$OGKM/src/common/unix/nvidia-push/interface" -I"$KMS/interface" -I"$KMS/include"
         -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset" -I"$OGKM/src/common/unix/common/utils/interface" )
RMDEFS=(); while read -r d; do RMDEFS+=("$d"); done < <(head -1 "$NV/_out/Darwin_x86_64/compile_cmds.sh" | tr ' ' '\n' | grep -E '^-D' | sed -e 's/"//g' | grep -v -E '^-D(NVRM|_LANGUAGE_C)$')
CFLAGS=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" -I"$SRC" -I"$SRC/fb" "${RMINC[@]}" "${KMSINC[@]}"
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT "${RMDEFS[@]}"
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 )
xcrun clang++ "${CFLAGS[@]}" -c "$SRC/fb/nvrm-fb.cpp" -o "$OUT/nvrm-fb.o" 2>"$OUT/fb.err" || { grep error "$OUT/fb.err" | head; exit 1; }
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext "$OUT/nvrm-fb.o" -o "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB" 2>"$OUT/fbld.err" || { head "$OUT/fbld.err"; exit 1; }
cp "$SRC/fb/Info.plist" "$OUT/NVRMFB.kext/Contents/Info.plist"
echo "NVRMFB $(md5 -q "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB") $(stat -f %z "$OUT/NVRMFB.kext/Contents/MacOS/NVRMFB") B  ($(xcrun clang++ --version | head -1))"
echo "$OUT/NVRMFB.kext"

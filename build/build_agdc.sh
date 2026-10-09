#!/bin/bash
# Build NVRMAGDC.kext, the AppleGraphicsDeviceControl policy shim, from this checkout.
#
#   build/build_agdc.sh [src] [out]      (default: kexts/NVRMAGDC -> out/agdc/NVRMAGDC.kext)
#
# Needs macOS with Xcode: the kext uses Kernel.framework headers and links only Apple's KPIs and AGDC.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
D=${1:-$REPO/kexts/NVRMAGDC}; B=${2:-$REPO/out/agdc}
command -v xcrun >/dev/null 2>&1 || { echo "STOP: xcrun not found; kexts need macOS with Xcode"; exit 2; }
[ -f "$D/nvrm-agdc.cpp" ] || { echo "STOP: no NVRMAGDC source at $D"; exit 2; }
rm -rf "$B"; mkdir -p "$B/NVRMAGDC.kext/Contents/MacOS"
SDK="$(xcrun --show-sdk-path)"; KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
xcrun clang++ -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" -I"$D" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 \
  -c "$D/nvrm-agdc.cpp" -o "$B/k1.o" 2>"$B/cc.err" || { grep error "$B/cc.err" | head; exit 1; }
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext "$B/k1.o" -o "$B/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC" 2>"$B/ld.err" || { head "$B/ld.err"; exit 1; }
cp "$D/Info.plist" "$B/NVRMAGDC.kext/Contents/Info.plist"
echo "NVRMAGDC $(md5 -q "$B/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC") $(dwarfdump --uuid "$B/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC" | awk '{print $2}')  warnings $(grep -c ': warning:' "$B/cc.err")"
echo "$B/NVRMAGDC.kext"

#!/bin/bash
# Build the NullMoth NVIDIA driver from this checkout: every component this machine can build, and a plain statement
# of what it cannot build and why.
#
#   build/build.sh                                        builds everything whose prerequisites are present
#   build/build.sh check                                  only reports what this machine can build
#   build/build.sh translator plugin agdc fb accel nvk app      any subset, built in this order
#
# Outputs land in out/. RELEASE=1 selects the shipping plugin build. The component scripts read VULKAN_HEADERS, OGKM,
# MESA_SRC, X, PLUGIN_SRC, OUT, TARGET and ALLOW_DIRTY; each script's header documents them.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO" || exit 2
OGKM=${OGKM:-$HOME/ogkm610}; VH=${VULKAN_HEADERS:-$HOME/Vulkan-Headers}; MESA_SRC=${MESA_SRC:-$REPO/nvk/mesa}
ALL="translator plugin agdc fb accel nvk app"
have() { command -v "$1" >/dev/null 2>&1; }
# Each why_* prints why its component cannot be built on this machine, or nothing when it can.
why_translator() { have cargo || { echo "no cargo: install a stable Rust toolchain (https://rustup.rs)"; return; }; have xcrun || echo "no Xcode (xcrun)"; }
why_plugin()     { have xcrun || { echo "no Xcode (xcrun)"; return; }
                   [ -f "$VH/include/vulkan/vulkan_core.h" ] || echo "no Vulkan-Headers at $VH: git clone https://github.com/KhronosGroup/Vulkan-Headers \"$VH\" (or set VULKAN_HEADERS)"; }
why_agdc()       { have xcrun || echo "no Xcode (xcrun)"; }
why_rm_kext()    { have xcrun || { echo "no Xcode (xcrun)"; return; }
                   [ -f "$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh" ] || echo "no Darwin build of open-gpu-kernel-modules 610.57.04 at $OGKM (set OGKM): NVIDIA publishes a Linux build system only, and the Darwin port that produces src/nvidia/_out/Darwin_x86_64 is not in this repository"; }
why_fb()         { why_rm_kext; }
why_accel()      { why_rm_kext; }
why_nvk()        { have xcrun || { echo "no Xcode (xcrun)"; return; }
                   for t in meson ninja glslangValidator mesa_clc cargo bindgen cbindgen; do have "$t" || { echo "no $t on PATH (prerequisites: build/build263.sh)"; return; }; done
                   [ -f "$MESA_SRC/src/nouveau/vulkan/nvmtl_nvk_sass.c" ] || echo "no patched Mesa tree at $MESA_SRC: run nvk/prepare-mesa.sh"; }
why_app()        { have xcrun || echo "no Xcode (xcrun, swiftc)"; }
build_translator() { build/build_xlate.sh; }
build_plugin()     { build/build_plugin.sh; }
build_agdc()       { build/build_agdc.sh; }
build_fb()         { build/fb_build.sh; }
build_accel()      { build/accel_build.sh kexts/NVRM out/accel; }
build_nvk()        { build/build263.sh; }
build_app()        { app/build.sh "$REPO/out/app"; }

mode=build; [ "${1:-}" = check ] && { mode=check; shift; }
want=${*:-$ALL}
for c in $want; do case " $ALL " in *" $c "*) ;; *) echo "unknown component '$c' (one of: $ALL, or check)"; exit 2;; esac; done
rows=""; failed=0
for c in $want; do
  why=$("why_$c")
  if [ -n "$why" ]; then rows="$rows$c|skipped|$why
"; continue; fi
  if [ "$mode" = check ]; then rows="$rows$c|ready|prerequisites present
"; continue; fi
  echo; echo "== $c"
  if "build_$c"; then rows="$rows$c|built|
"; else failed=1; rows="$rows$c|FAILED|see the output above
"; fi
done
echo; echo "component    result   note"
printf '%s' "$rows" | while IFS='|' read -r c s n; do [ -n "$c" ] && printf '%-12s %-8s %s\n' "$c" "$s" "$n"; done
cat <<'T'
NVRM.kext    none     no build recipe in this repository: NVRM links libnvkernel.a and libnvkms.a from the Darwin port
                      of NVIDIA's open-gpu-kernel-modules 610.57.04 (kexts/NVRM/rmcc.py and build-completion-archive.py
                      expect its src/nvidia/_out/Darwin_x86_64); that port is not published
package      none     NVMTLDriver.bundle's Info.plist, NVIDIAShared.bundle (NVIDIA's NVVM compiler), the Vulkan loader
                      (libvulkan.dylib, nvk_icd.json), air-opt and the GSP firmware come from a release package
T
[ "$failed" = 0 ]

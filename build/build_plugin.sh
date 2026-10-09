#!/bin/bash
# Build NVMTLDriver, the Metal driver plugin executable (NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver), from this checkout.
#
#   build/build_plugin.sh               -> out/plugin/plugin-<commit>/NVMTLDriver          (diagnostics in)
#   RELEASE=1 build/build_plugin.sh     -> out/plugin/plugin-<commit>-release/NVMTLDriver  (every diagnostic stripped: the shipping build)
#
# Environment (all optional):
#   PLUGIN_SRC      plugin tree                 (default: <repo>/plugin)
#   OUT             output directory            (default: <repo>/out/plugin)
#   VULKAN_HEADERS  Khronos Vulkan-Headers tree (default: the pinned checkout build/fetch-deps.sh makes in
#                   out/deps, else ~/Vulkan-Headers). RELEASE=1 accepts only the pinned commit (build/inputs.lock).
#   ALLOW_DIRTY=1   build with uncommitted edits in the tree
#
# Needs macOS with Xcode 16: the plugin links Metal.framework and IOSurface.framework.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=build/pins.sh
. "$REPO/build/pins.sh"
S=${PLUGIN_SRC:-$REPO/plugin}; OUT=${OUT:-$REPO/out/plugin}; VH=$(vulkan_headers_dir)
command -v xcrun >/dev/null 2>&1 || { echo "STOP: xcrun not found; the plugin needs macOS with Xcode 16"; exit 2; }
[ -f "$VH/include/vulkan/vulkan_core.h" ] || { echo "STOP: no Vulkan headers at $VH: run build/fetch-deps.sh (or set VULKAN_HEADERS)"; exit 2; }
require_pinned_vulkan_headers "$VH" || exit 2
[ -f "$S/NVMTLDevice.m" ] || { echo "STOP: no plugin tree at $S (set PLUGIN_SRC)"; exit 2; }
cd "$S" || exit 2
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  echo "STOP: the plugin tree has uncommitted edits (ALLOW_DIRTY=1 builds anyway):"; git status --short -- . | head; exit 3
fi
C=$(git rev-parse --short HEAD 2>/dev/null || echo nogit); O=$OUT/plugin-$C${RELEASE:+-release}; mkdir -p "$O"
RDEF=""; [ -n "${RELEASE:-}" ] && RDEF="-DNVMTL_RELEASE=1"
# NVMTLDevice.m #imports the other .m files and nvmtl_vk.c: the plugin is one translation unit.
xcrun clang -arch x86_64 -bundle -fobjc-arc -O1 $RDEF -Wno-protocol -Wno-incomplete-implementation \
  -I"$VH/include" -o "$O/NVMTLDriver" NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface 2>"$O/NVMTLDriver.err" \
  || { echo "STOP: compile failed"; grep -A2 ': error:' "$O/NVMTLDriver.err" | head -30; exit 5; }
codesign -f -s - "$O/NVMTLDriver" 2>/dev/null
# Every live feature leaves a marker string in the binary; a build missing one is not the driver we think it is.
miss=0
while IFS='|' read -r feat pat; do
  [ -z "$feat" ] && continue
  n=$(strings -a "$O/NVMTLDriver" | grep -c -- "$pat")
  case "$feat" in "fps file"|"passtime instrument")
    if [ -n "${RELEASE:-}" ]; then [ "$n" -eq 0 ] || { echo "  LEAKED diagnostic $feat  ($pat)"; miss=$((miss+1)); }; continue; fi;; esac
  [ "$n" -ge 1 ] || { echo "  MISSING $feat  ($pat)"; miss=$((miss+1)); }
done <<'M'
vendor compiler lane (NVIDIAShared)|NVIDIAShared
SASS dispatch on NVK (sasspipe)|nvmtl_nvk_dispatch_sass_v1
vendor variant (Apple MTLCompiler handshake)|vendor variant
bindless-all heap slots|bindless-all - textures reach shaders
dirty-only bindings|NVMTL_NO_DIRTYONLY
fullclear (Apple whole-attachment clear)|begin_render: fullclear
per-stage binding mask (gfx-bmask)|gmask
fps file|nvmtl-fps-
passtime instrument|nvmtl-passtime-request
library key memo (xlate)|library key memo: hit
res2-evict (Apple order: newest wins the card)|on the allocating thread
M
echo "plugin-$C  sha $(shasum -a 256 "$O/NVMTLDriver" | cut -c1-8)  uuid $(otool -l "$O/NVMTLDriver" | awk '/uuid/{print $2; exit}')  warnings $(grep -c ': warning:' "$O/NVMTLDriver.err")  markers-missing $miss"
[ "$miss" = 0 ] || { echo "STOP: a live feature is missing from this build; do NOT ship it"; exit 6; }
echo "$O/NVMTLDriver"

#!/bin/bash
# Build nvk-compute-check, the Vulkan compute probe that runs on the NVIDIA card through NVK's ICD, outside Metal
# (tools/nvk-compute-check/main.c). The binary links no Vulkan library: it dlopen()s the loader the driver installs.
#
#   build/build_compute_check.sh [out]     (default: out/compute-check/nvk-compute-check)
#
# Needs macOS with Xcode and the Khronos Vulkan headers (VULKAN_HEADERS; default: the pinned checkout from
# build/fetch-deps.sh, else ~/Vulkan-Headers). RELEASE=1 accepts only the pinned commit.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=build/pins.sh
. "$REPO/build/pins.sh"
OUT=${1:-$REPO/out/compute-check}; VH=$(vulkan_headers_dir); SRC=$REPO/tools/nvk-compute-check
command -v xcrun >/dev/null 2>&1 || { echo "STOP: xcrun not found; this script builds the macOS binary (on Linux: gcc -O2 -o nvk-compute-check main.c -ldl)"; exit 2; }
[ -f "$VH/include/vulkan/vulkan_core.h" ] || { echo "STOP: no Vulkan headers at $VH: run build/fetch-deps.sh (or set VULKAN_HEADERS)"; exit 2; }
require_pinned_vulkan_headers "$VH" || exit 2
mkdir -p "$OUT"
xcrun clang -arch x86_64 -std=c11 -O2 -Wall -Wextra -Werror -I"$VH/include" -o "$OUT/nvk-compute-check" "$SRC/main.c" 2>"$OUT/cc.err" \
  || { grep -A2 'error' "$OUT/cc.err" | head -20; exit 1; }
codesign -f -s - "$OUT/nvk-compute-check" 2>/dev/null
echo "nvk-compute-check sha $(shasum -a 256 "$OUT/nvk-compute-check" | cut -c1-8)  warnings $(grep -c ': warning:' "$OUT/cc.err")"
echo "$OUT/nvk-compute-check"

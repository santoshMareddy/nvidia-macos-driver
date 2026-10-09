#!/bin/bash
# Build NVK, libvulkan_nouveau.dylib (Mesa's Vulkan driver for NVIDIA plus the NAK compiler), for macOS.
#
#   nvk/prepare-mesa.sh          makes the source tree: Mesa at nvk/MESA_BASE with nvk/nvk-macos.patch applied
#   build/build263.sh            -> out/nvk/libvulkan_nouveau.dylib
#
# Environment (all optional):
#   MESA_SRC   the prepared Mesa tree   (default: <repo>/nvk/mesa)
#   BUILD      meson build directory    (default: $MESA_SRC/build263)
#   OUT        output directory         (default: <repo>/out/nvk)
#
# Needs macOS with Xcode 16, meson, ninja, python3 with mako and pyyaml, a stable Rust toolchain with bindgen and
# cbindgen (NAK is Rust), glslang (the BVH shaders), and a mesa_clc binary on PATH (-Dmesa-clc=system: the OpenCL C
# kernels NVK carries are compiled by a mesa_clc from a Mesa built with LLVM and libclc; this build has no LLVM).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
S=${MESA_SRC:-$REPO/nvk/mesa}; B=${BUILD:-$S/build263}; O=${OUT:-$REPO/out/nvk}; LOG=$O/logs
[ -f "$S/VERSION" ] || { echo "STOP: no Mesa tree at $S (run nvk/prepare-mesa.sh, or set MESA_SRC)"; exit 2; }
[ -e "$S/.git" ] && { echo "STOP: $S has a .git (Mesa would stamp git-<sha> into the binary; nvk/prepare-mesa.sh removes it)"; exit 2; }
[ -f "$S/src/nouveau/vulkan/nvmtl_nvk_sass.c" ] || { echo "STOP: nvk/nvk-macos.patch is not applied to $S (nvk/prepare-mesa.sh applies it)"; exit 2; }
for t in xcrun meson ninja glslangValidator mesa_clc cargo bindgen cbindgen; do
  command -v "$t" >/dev/null 2>&1 || { echo "STOP: $t not on PATH (see the prerequisites at the top of this script)"; exit 2; }
done
mkdir -p "$LOG"
if [ ! -f "$B/build.ninja" ]; then
  meson setup "$B" "$S" -Dbuildtype=debugoptimized -Dvulkan-drivers=nouveau -Dgallium-drivers= -Dplatforms= \
    -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled -Dmesa-clc=system -Dshared-glapi=disabled \
    -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled \
    -Dlmsensors=disabled -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false -Dspirv-tools=disabled \
    > "$LOG/setup.log" 2>&1
  rc=$?
  [ $rc = 0 ] || { echo "STOP: meson setup failed rc=$rc"; tail -30 "$LOG/setup.log"; exit 3; }
fi
# Paths are remapped so the binary carries no build-machine directory names.
meson configure "$B" "-Dc_args=-ffile-prefix-map=$S=/src -ffile-prefix-map=$HOME=/build" "-Dcpp_args=-ffile-prefix-map=$S=/src -ffile-prefix-map=$HOME=/build" "-Drust_args=--remap-path-prefix=$S=/src --remap-path-prefix=$HOME=/build" > "$LOG/configure.log" 2>&1 || { echo "STOP: meson configure failed"; tail -5 "$LOG/configure.log"; exit 3; }
nice ninja -C "$B" -k 0 src/nouveau/vulkan/libvulkan_nouveau.dylib > "$LOG/ninja.log" 2>&1
rc=$?
echo "ninja rc=$rc  errors=$(grep -c -E 'error(\[E[0-9]+\])?:' "$LOG/ninja.log")  FAILED=$(grep -c '^FAILED' "$LOG/ninja.log")"
[ $rc = 0 ] || { grep -E -m 10 'error(\[E[0-9]+\])?:' "$LOG/ninja.log"; exit 4; }
U=$(nm -m "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" | grep '(undefined)' | grep -v weak | grep 'dynamically looked up')
[ -z "$U" ] || { echo "STOP: unresolved strong references (dlopen fails in WindowServer):"; echo "$U"; exit 5; }
D=$O/libvulkan_nouveau.dylib; cp "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" "$D"; strip -S "$D"   # debug-map stabs name every .o by absolute path
echo "built: $(shasum -a 256 "$D" | cut -c1-8)  uuid $(otool -l "$D" | awk '/uuid/{print $2; exit}')  $D"

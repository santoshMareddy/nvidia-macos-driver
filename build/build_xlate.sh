#!/bin/bash
# Build libnvmtl_translate.dylib, the Apple AIR -> SPIR-V shader translator, from this checkout.
#
#   build/build_xlate.sh                 -> out/xlate/xlate-<commit>/libnvmtl_translate.dylib
#
# Environment (all optional):
#   X              translator tree          (default: <repo>/translator)
#   OUT            output directory         (default: <repo>/out/xlate)
#   TARGET         Rust target triple       (default: x86_64-apple-darwin; the driver is x86_64 only)
#   ALLOW_DIRTY=1  build with uncommitted edits in the tree (the result then matches no commit)
#   RELEASE=1      production build: the Rust toolchain must be the one translator/rust-toolchain.toml pins
#
# Needs macOS with Xcode (strip, install_name_tool, codesign, otool) and rustup (https://rustup.rs), which installs
# the pinned toolchain. Crates come from the Cargo.lock files only (--locked).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
X=${X:-$REPO/translator}; OUT=${OUT:-$REPO/out/xlate}; TARGET=${TARGET:-x86_64-apple-darwin}
command -v cargo >/dev/null 2>&1 || { echo "STOP: cargo not found; install a stable Rust toolchain (https://rustup.rs)"; exit 2; }
command -v xcrun  >/dev/null 2>&1 || { echo "STOP: xcrun not found; this builds a macOS dylib and needs Xcode"; exit 2; }
[ -f "$X/wrapper/Cargo.toml" ] || { echo "STOP: no translator tree at $X (set X)"; exit 2; }
cd "$X" || exit 2
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  echo "STOP: the translator tree has uncommitted edits (ALLOW_DIRTY=1 builds anyway):"; git status --short -- . | head; exit 3
fi
C=$(git rev-parse --short HEAD 2>/dev/null || echo nogit); O=$OUT/xlate-$C; mkdir -p "$O"
TC=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$X/rust-toolchain.toml" 2>/dev/null || true)
if [ -n "$TC" ] && command -v rustup >/dev/null 2>&1; then
  rustup toolchain install --no-self-update "$TC" --profile minimal --target "$TARGET" >/dev/null 2>&1 \
    || { echo "STOP: cannot install the pinned Rust toolchain $TC with target $TARGET"; exit 4; }
elif command -v rustup >/dev/null 2>&1 && ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  rustup target add "$TARGET" || { echo "STOP: cannot add the Rust target $TARGET"; exit 4; }
fi
RV=$(rustc --version 2>/dev/null || echo "rustc missing")          # run inside $X: the toolchain file applies
if [ -n "$TC" ] && [ "${RV#rustc "$TC" }" = "$RV" ]; then
  [ -n "${RELEASE:-}" ] && { echo "STOP: a RELEASE build uses Rust $TC (translator/rust-toolchain.toml); this is $RV"; exit 4; }
  echo "NOTE: $RV is not the pinned Rust $TC; fine for development, refused when RELEASE=1"
fi
# Paths are remapped so the binary carries no build-machine directory names.
export RUSTFLAGS="--remap-path-prefix=$X=/src --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME=/build"
cargo build --release --locked --target "$TARGET" --manifest-path wrapper/Cargo.toml --target-dir "$X/target" > "$O/cargo.log" 2>&1; rc=$?
grep -E "^(error|warning)" "$O/cargo.log" | head -20
[ "$rc" = 0 ] || { echo "STOP: cargo build failed (rc $rc), see $O/cargo.log"; exit 4; }
D=$O/libnvmtl_translate.dylib
cp "$X/target/$TARGET/release/libnvmtl_translate.dylib" "$D" || exit 4
strip -S "$D"                                        # debug-map stabs name every .o by absolute path
install_name_tool -id @rpath/libnvmtl_translate.dylib "$D" && codesign -f -s - "$D" 2>/dev/null
miss=0
for p in NVMTL_NO_BINDLESS_ALL NVMTL_NO_TIER2; do      # environment knobs the plugin documents: their names must survive
  [ "$(strings -a "$D" | grep -c -- "$p")" -ge 1 ] || { echo "  MISSING marker $p"; miss=$((miss+1)); }
done
gone=$(comm -23 <(grep -v '^#' "$X/wrapper/exports.txt" | sort) <(nm -gU "$D" | awk '{print $3}' | sort))
[ -z "$gone" ] || { echo "  MISSING export(s) the plugin dlsym()s:"; echo "$gone" | sed 's/^/    /'; miss=$((miss+1)); }
echo "xlate-$C  sha $(shasum -a 256 "$D" | cut -c1-8)  uuid $(otool -l "$D" | awk '/uuid/{print $2; exit}')  missing $miss  ($RV)"
[ "$miss" = 0 ] || { echo "STOP: do NOT ship this build"; exit 6; }
echo "$D"

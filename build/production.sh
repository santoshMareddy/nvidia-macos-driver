#!/bin/bash
# The production build: every open component built with locked inputs into out/production, plus SHA256SUMS (one line
# per file, bundle contents included; what CI attests) and BUILD-MANIFEST.txt (commit, toolchains, pinned inputs).
#
#   build/production.sh             build and record
#   REPRO=1 build/production.sh     then build the same commit again from a second checkout at another path and
#                                   require byte-identical files (the reproducibility lock)
#
# Locked means: built from a clean commit; crates only from the Cargo.lock files (--locked); the Rust toolchain from
# translator/rust-toolchain.toml; the Vulkan headers from build/inputs.lock (build/fetch-deps.sh); the plugin's
# shipping variant (RELEASE=1, every diagnostic stripped). Needs macOS with Xcode 16 and rustup.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
# shellcheck source=build/pins.sh
. "$REPO/build/pins.sh"
command -v xcrun >/dev/null 2>&1 || { echo "STOP: the production build needs macOS with Xcode"; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "STOP: uncommitted changes; a production build is made from a commit:"; git status --short | head; exit 3; }
COMMIT=$(git rev-parse HEAD)
build/fetch-deps.sh
export RELEASE=1 VULKAN_HEADERS=$PINNED_VULKAN_HEADERS
P=$REPO/out/production; L=$REPO/out/production-logs
rm -rf "$P" "$L"; mkdir -p "$P" "$L"

# build_set ROOT OUT LOGS: build every component of the checkout at ROOT; the files land in OUT, flat.
build_set() {
  local root=$1 out=$2 logs=$3 w; w=$(mktemp -d "${TMPDIR:-/tmp}/nm-production.XXXXXX")
  mkdir -p "$out" "$logs"
  run() { local name=$1; shift; echo "  $name"; "$@" >"$logs/$name.log" 2>&1 || { tail -30 "$logs/$name.log"; echo "STOP: $name failed (full log $logs/$name.log)"; exit 4; }; }
  run translator    env OUT="$w/xlate" "$root/build/build_xlate.sh"
  run plugin        env OUT="$w/plugin" "$root/build/build_plugin.sh"
  run nvrmagdc      "$root/build/build_agdc.sh" "$root/kexts/NVRMAGDC" "$w/agdc"
  run app           "$root/app/build.sh" "$w/app"
  run computecheck  "$root/build/build_compute_check.sh" "$w/compute-check"
  cp "$w"/xlate/xlate-*/libnvmtl_translate.dylib "$w"/plugin/plugin-*-release/NVMTLDriver "$w/compute-check/nvk-compute-check" "$out/"
  ditto "$w/agdc/NVRMAGDC.kext" "$out/NVRMAGDC.kext"
  ditto "$w/app/1401.app" "$out/1401.app"
  rm -rf "$w"
}
# sums DIR: one SHA-256 line per file under DIR, bundle contents included, sorted by path.
sums() { (cd "$1" && find . -type f ! -name SHA256SUMS ! -name BUILD-MANIFEST.txt -print | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done); }

echo "== production build of $COMMIT"
build_set "$REPO" "$P" "$L"
sums "$P" > "$P/SHA256SUMS"
{
  echo "NullMoth NVIDIA driver: production build of the open components"
  echo "commit:          $COMMIT ($(git log -1 --format=%cI))"
  echo "built:           $(date -u +%Y-%m-%dT%H:%M:%SZ) on macOS $(sw_vers -productVersion) $(sw_vers -buildVersion) $(uname -m)"
  echo "xcode:           $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
  echo "clang:           $(xcrun clang --version | head -1)"
  echo "swiftc:          $(xcrun swiftc --version 2>&1 | head -1)"
  echo "rustc:           $(cd translator && rustc --version)"
  echo "cargo:           $(cd translator && cargo --version)"
  echo "pinned inputs:"
  echo "  Rust toolchain $(pinned_rust_toolchain) (translator/rust-toolchain.toml)"
  echo "  Vulkan-Headers $VULKAN_HEADERS_TAG $VULKAN_HEADERS_COMMIT (build/inputs.lock)"
  echo "  Mesa           $(tr -d '[:space:]' < nvk/MESA_BASE) (nvk/MESA_BASE; NVK is not part of this build)"
  for lock in translator/wrapper/Cargo.lock translator/translator/Cargo.lock; do echo "  $lock sha256 $(shasum -a 256 "$lock" | cut -d' ' -f1)"; done
  echo "variant:         plugin RELEASE=1 (diagnostics stripped and checked absent)"
  echo "not built here:  NVRM.kext, NVRMFB.kext, NVAccel.kext (need the Darwin build of NVIDIA's kernel modules),"
  echo "                 NVK (needs mesa_clc), NVIDIAShared.bundle, the Vulkan loader and GSP firmware (release package)"
  echo "files:           $(wc -l < "$P/SHA256SUMS" | tr -d ' ') (SHA256SUMS)"
} > "$P/BUILD-MANIFEST.txt"
cat "$P/BUILD-MANIFEST.txt"

if [ -n "${REPRO:-}" ]; then
  R=$(mktemp -d "${TMPDIR:-/tmp}/nm-repro.XXXXXX")
  echo "== reproducibility: the same commit from a second checkout at $R/src"
  git worktree add -q --detach "$R/src" "$COMMIT"
  trap 'git -C "$REPO" worktree remove --force "$R/src" >/dev/null 2>&1 || true' EXIT
  build_set "$R/src" "$R/out" "$L/repro"
  sums "$R/out" > "$R/SHA256SUMS"
  if diff -u "$P/SHA256SUMS" "$R/SHA256SUMS" > "$L/repro.diff"; then
    echo "REPRODUCIBLE: all $(wc -l < "$P/SHA256SUMS" | tr -d ' ') files are byte-identical across the two checkouts"
    echo "reproducible:    yes, $(wc -l < "$P/SHA256SUMS" | tr -d ' ') files byte-identical from a second checkout at another path" >> "$P/BUILD-MANIFEST.txt"
  else
    echo "NOT REPRODUCIBLE: these files differ between the two checkouts:"
    grep -E '^[-+][0-9a-f]{64} ' "$L/repro.diff" | sed -E 's/^[-+][0-9a-f]{64} +//' | sort -u | sed 's/^/  /'
    exit 5
  fi
fi
echo "$P"

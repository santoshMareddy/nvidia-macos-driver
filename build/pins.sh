# shellcheck shell=bash
# Sourced by the build scripts: the pinned third-party inputs (build/inputs.lock) and the checks that hold a
# production build to them.
PINS_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=build/inputs.lock
. "$PINS_REPO/build/inputs.lock"
PINNED_VULKAN_HEADERS=$PINS_REPO/out/deps/Vulkan-Headers

# The Vulkan headers to compile against: $VULKAN_HEADERS when set, else the pinned checkout build/fetch-deps.sh
# makes, else ~/Vulkan-Headers.
vulkan_headers_dir() {
  if [ -n "${VULKAN_HEADERS:-}" ]; then printf '%s\n' "$VULKAN_HEADERS"
  elif [ -d "$PINNED_VULKAN_HEADERS/include/vulkan" ]; then printf '%s\n' "$PINNED_VULKAN_HEADERS"
  else printf '%s\n' "$HOME/Vulkan-Headers"; fi
}

# vulkan_headers_pinned DIR: true when DIR is its own clean git checkout of the pinned commit.
vulkan_headers_pinned() {
  [ -e "$1/.git" ] && [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$VULKAN_HEADERS_COMMIT" ] &&
    [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# require_pinned_vulkan_headers DIR: a RELEASE=1 build stops on unpinned headers; any other build says so and goes on.
require_pinned_vulkan_headers() {
  if vulkan_headers_pinned "$1"; then return 0; fi
  if [ -n "${RELEASE:-}" ]; then
    echo "STOP: a RELEASE build compiles against Vulkan-Headers $VULKAN_HEADERS_TAG ($VULKAN_HEADERS_COMMIT) only; $1 is not that clean checkout. Run build/fetch-deps.sh"
    return 1
  fi
  echo "NOTE: $1 is not the pinned Vulkan-Headers $VULKAN_HEADERS_TAG; fine for development, refused when RELEASE=1 (build/fetch-deps.sh)"
}

# The Rust toolchain the translator is locked to (translator/rust-toolchain.toml).
pinned_rust_toolchain() { sed -n 's/^channel *= *"\(.*\)"/\1/p' "$PINS_REPO/translator/rust-toolchain.toml" 2>/dev/null; }

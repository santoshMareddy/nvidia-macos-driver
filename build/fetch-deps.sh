#!/bin/bash
# Fetch the pinned third-party inputs (build/inputs.lock) into out/deps and verify them by commit.
#
#   build/fetch-deps.sh
#
# Needs git and network access to github.com. The commit is the lock; the tag is checked only to say if upstream
# moved it.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=build/pins.sh
. "$REPO/build/pins.sh"
D=$PINNED_VULKAN_HEADERS
if vulkan_headers_pinned "$D"; then echo "Vulkan-Headers $VULKAN_HEADERS_TAG ($VULKAN_HEADERS_COMMIT) is at $D"; exit 0; fi
case "$D" in "$REPO"/out/deps/*) rm -rf "$D";; *) echo "STOP: refusing to replace $D"; exit 2;; esac
mkdir -p "$D"
git -C "$D" init -q
git -C "$D" fetch -q --depth 1 "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_COMMIT"
git -C "$D" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
vulkan_headers_pinned "$D" || { echo "STOP: $D is not $VULKAN_HEADERS_COMMIT after the fetch"; exit 3; }
tagged=$(git ls-remote "$VULKAN_HEADERS_URL" "refs/tags/$VULKAN_HEADERS_TAG" "refs/tags/$VULKAN_HEADERS_TAG^{}" 2>/dev/null |
  awk '$2 ~ /\^\{\}$/ {p=$1} $2 !~ /\^\{\}$/ {d=$1} END {print (p != "" ? p : d)}') || tagged=""
if [ -n "$tagged" ] && [ "$tagged" != "$VULKAN_HEADERS_COMMIT" ]; then
  echo "WARNING: upstream tag $VULKAN_HEADERS_TAG now points at $tagged, not the pinned $VULKAN_HEADERS_COMMIT; the build keeps the pinned commit"
fi
echo "Vulkan-Headers $VULKAN_HEADERS_TAG ($VULKAN_HEADERS_COMMIT) fetched to $D"

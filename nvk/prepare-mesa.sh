#!/bin/bash
# Make the Mesa tree NVK is built from: Mesa at the commit in nvk/MESA_BASE with nvk/nvk-macos.patch applied.
#
#   nvk/prepare-mesa.sh [dest]           (default: <repo>/nvk/mesa, or $MESA_SRC)
#
# Then build/build263.sh builds libvulkan_nouveau.dylib from it. Needs git, patch, curl and python3; network access to
# gitlab.freedesktop.org. MESA_URL overrides the repository (a mirror must contain the same commit).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-${MESA_SRC:-$REPO/nvk/mesa}}
BASE=$(tr -d '[:space:]' < "$REPO/nvk/MESA_BASE")
PATCH=$REPO/nvk/nvk-macos.patch
MESA_URL=${MESA_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}
for t in git patch curl python3; do command -v "$t" >/dev/null 2>&1 || { echo "STOP: $t not found"; exit 2; }; done
[ ! -e "$DEST" ] || { echo "STOP: $DEST exists; remove it, or name another directory, so the tree starts clean"; exit 2; }
FULL=$BASE
if [ ${#BASE} -lt 40 ]; then   # git cannot fetch an abbreviated commit id: resolve it through GitLab's API
  api="https://gitlab.freedesktop.org/api/v4/projects/mesa%2Fmesa/repository/commits/$BASE"
  FULL=$(curl -fsSL "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || { echo "STOP: cannot resolve Mesa commit $BASE through $api"; exit 3; }
fi
case "$FULL" in *[!0-9a-f]*|"") echo "STOP: '$FULL' is not a commit id"; exit 3;; esac
echo "Mesa base $BASE = $FULL"
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin "$MESA_URL"
if ! git -C "$DEST" fetch -q --depth 1 origin "$FULL"; then
  echo "the server refused a shallow fetch of $FULL; cloning the full history instead"
  rm -rf "$DEST"; git clone -q "$MESA_URL" "$DEST"
  git -C "$DEST" fetch -q origin "$FULL" || true
fi
git -C "$DEST" -c advice.detachedHead=false checkout -q "$FULL"
[ "$(git -C "$DEST" rev-parse HEAD)" = "$FULL" ] || { echo "STOP: checkout did not land on $FULL"; exit 4; }
rm -rf "$DEST/.git"              # build263.sh refuses a tree with .git: Mesa would stamp git-<sha> into the binary
(cd "$DEST" && patch -p1 --batch --forward --no-backup-if-mismatch < "$PATCH") > "$DEST/.nvmtl-patch.log" 2>&1 \
  || { tail -20 "$DEST/.nvmtl-patch.log"; echo "STOP: nvk-macos.patch did not apply to Mesa $FULL"; exit 5; }
rej=$(find "$DEST" -name '*.rej' | head -20)
[ -z "$rej" ] || { echo "STOP: rejected hunks:"; echo "$rej"; exit 5; }
grep -E 'fuzz|offset' "$DEST/.nvmtl-patch.log" | head -20 || true     # applied, but not at the recorded lines: worth a look
printf '%s\n' "$FULL" > "$DEST/.nvmtl-base"
echo "ready: $DEST = Mesa $FULL + nvk/nvk-macos.patch ($(grep -c '^patching file' "$DEST/.nvmtl-patch.log") files)"

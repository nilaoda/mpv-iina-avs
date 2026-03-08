#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

IINA_REPO="${1:-}"
BUNDLE_ROOT="${BUNDLE_ROOT:-$WORK_ROOT/iina-bundle}"

[[ -n "$IINA_REPO" ]] || {
  echo "Usage: $0 /absolute/path/to/iina-avs" >&2
  exit 1
}

DEST_DIR="$IINA_REPO/deps/lib"
[[ -d "$IINA_REPO" ]] || { echo "IINA repo not found: $IINA_REPO" >&2; exit 1; }
[[ -d "$BUNDLE_ROOT" ]] || { echo "Bundle root not found: $BUNDLE_ROOT" >&2; exit 1; }

mkdir -p "$DEST_DIR"
cp -f "$BUNDLE_ROOT"/*.dylib "$DEST_DIR"/

echo "Synced dylibs to $DEST_DIR"
echo "If libmpv headers changed, also sync deps/include/mpv and regenerate IINA's generated mpv option/property files."

#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

IINA_REPO="${1:-}"
BUNDLE_ROOT="${BUNDLE_ROOT:-$WORK_ROOT/iina-bundle}"

[[ -n "$IINA_REPO" ]] || {
  echo "Usage: $0 /absolute/path/to/iina-avs" >&2
  exit 1
}

[[ -d "$IINA_REPO" ]] || { echo "IINA repo not found: $IINA_REPO" >&2; exit 1; }
[[ -d "$BUNDLE_ROOT" ]] || { echo "Bundle root not found: $BUNDLE_ROOT" >&2; exit 1; }

require_cmd python3
python3 "$IINA_REPO/other/custom_bundle.py" prepare \
  --repo "$IINA_REPO" --bundle "$BUNDLE_ROOT" --arch "$TARGET_ARCH" \
  --ffmpeg-version "$FFMPEG_VERSION" --mpv-ref "$MPV_REF"

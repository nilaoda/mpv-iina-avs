#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd ruby otool zip
BUNDLE_ROOT="$WORK_ROOT/iina-bundle"
MANIFEST_PATH="$ARTIFACT_ROOT/iina-bundle-manifest.txt"
PACKAGE_NAME="iina-mpv-bundle-macos-${TARGET_ARCH}-${LICENSE_FLAVOR}-ffmpeg-${FFMPEG_VERSION}-mpv-$(printf '%s' "$MPV_REF" | tr '/ ' '--')"
ZIP_PATH="$ARTIFACT_ROOT/$PACKAGE_NAME.zip"
LIBMPV_PATH=""
if [[ -f "$MPV_PREFIX/lib/libmpv.2.dylib" ]]; then
  LIBMPV_PATH="$MPV_PREFIX/lib/libmpv.2.dylib"
elif [[ -f "$MPV_PREFIX/lib/libmpv.dylib" ]]; then
  LIBMPV_PATH="$MPV_PREFIX/lib/libmpv.dylib"
else
  echo "Could not locate libmpv dylib under $MPV_PREFIX/lib" >&2
  exit 1
fi

rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT"

log "Collecting dylibs into bundle"
ruby "$REPO_ROOT/tools/collect_dylibs.rb" "$BUNDLE_ROOT" "$FFMPEG_PREFIX" "$MPV_PREFIX" "$LIBMPV_PATH"

{
  echo "Bundle root: $BUNDLE_ROOT"
  echo "libmpv path: $LIBMPV_PATH"
  echo "FFmpeg prefix: $FFMPEG_PREFIX"
  echo "mpv prefix: $MPV_PREFIX"
  echo
  echo "Bundled dylibs:"
  find "$BUNDLE_ROOT" -maxdepth 1 -type f -name '*.dylib' -print | sort
  echo
  echo "Dependency report:"
  for dylib in "$BUNDLE_ROOT"/*.dylib; do
    echo "## $(basename "$dylib")"
    otool -L "$dylib"
    echo
  done
} > "$MANIFEST_PATH"

(
  cd "$BUNDLE_ROOT"
  zip -qj "$ZIP_PATH" ./*.dylib
)

log "Created bundle: $ZIP_PATH"

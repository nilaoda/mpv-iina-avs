#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd ruby otool zip python3
if [[ "$TARGET_ARCH" == "x86_64" && -x /usr/local/bin/brew ]]; then
  BREW_PREFIX="$(/usr/local/bin/brew --prefix)"
else
  BREW_PREFIX="$(brew --prefix)"
fi
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
ruby "$REPO_ROOT/tools/collect_dylibs.rb" "$BUNDLE_ROOT" "$FFMPEG_PREFIX" "$MPV_PREFIX" "$BREW_PREFIX" "$LIBMPV_PATH"

# IINA also calls FFmpeg directly, including libraries libmpv may not link.
for library in avcodec avdevice avfilter avformat avutil swresample swscale; do
  ruby "$REPO_ROOT/tools/collect_dylibs.rb" "$BUNDLE_ROOT" "$FFMPEG_PREFIX" "$MPV_PREFIX" "$BREW_PREFIX" "$FFMPEG_PREFIX/lib/lib${library}.dylib"
done

# Ship the exact public headers used to build these libraries.
mkdir -p "$BUNDLE_ROOT/include"
for library in libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale; do
  cp -R "$FFMPEG_PREFIX/include/$library" "$BUNDLE_ROOT/include/"
done
cp -R "$MPV_PREFIX/include/mpv" "$BUNDLE_ROOT/include/"

FFMPEG_VERSION="$FFMPEG_VERSION" MPV_REF="$MPV_REF" TARGET_ARCH="$TARGET_ARCH" \
  BUNDLE_ROOT="$BUNDLE_ROOT" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ['BUNDLE_ROOT'])
metadata = {
    'schema_version': 1,
    'ffmpeg_version': os.environ['FFMPEG_VERSION'],
    'mpv_ref': os.environ['MPV_REF'],
    'arch': os.environ['TARGET_ARCH'],
    'render_backend': 'gpu-next',
    'dylibs': sorted(p.name for p in root.glob('*.dylib')),
}
(root / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY

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
  # Remove a previous archive so stale files cannot survive a rebuild.
  rm -f "$ZIP_PATH"
  zip -qr "$ZIP_PATH" ./*.dylib include bundle.json
)

log "Created bundle: $ZIP_PATH"

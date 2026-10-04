#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd ruby otool zip
BUNDLE_ROOT="$WORK_ROOT/ffmpeg-cli-bundle"
MANIFEST_PATH="$ARTIFACT_ROOT/ffmpeg-cli-bundle-manifest.txt"
PACKAGE_NAME="ffmpeg-cli-bundle-macos-${TARGET_ARCH}-${LICENSE_FLAVOR}-ffmpeg-${FFMPEG_VERSION}"
ZIP_PATH="$ARTIFACT_ROOT/$PACKAGE_NAME.zip"
FFMPEG_BIN="$FFMPEG_PREFIX/bin/ffmpeg"
FFPROBE_BIN="$FFMPEG_PREFIX/bin/ffprobe"
FFPLAY_BIN="$FFMPEG_PREFIX/bin/ffplay"

for binary in "$FFMPEG_BIN" "$FFPROBE_BIN" "$FFPLAY_BIN"; do
  if [[ ! -x "$binary" ]]; then
    echo "Required FFmpeg CLI binary not found: $binary" >&2
    exit 1
  fi
done

rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT"

log "Collecting FFmpeg CLI bundle"
package_prefixes=("$FFMPEG_PREFIX")
if [[ -n "${brew_prefix:-}" && -d "$brew_prefix/opt/sdl3" ]]; then
  package_prefixes+=("$brew_prefix/opt/sdl3")
fi
ruby "$REPO_ROOT/tools/package_macho_bundle.rb" \
  "$BUNDLE_ROOT" \
  "${package_prefixes[@]}" \
  -- \
  "$FFMPEG_BIN" \
  "$FFPROBE_BIN" \
  "$FFPLAY_BIN"

# SDL2 compatibility libraries may load SDL3 before ffplay parses its options.
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  "$BUNDLE_ROOT/bin/ffplay" -version > /dev/null

{
  echo "Bundle root: $BUNDLE_ROOT"
  echo "FFmpeg prefix: $FFMPEG_PREFIX"
  echo
  echo "Bundled binaries:"
  find "$BUNDLE_ROOT/bin" -maxdepth 1 -type f | sort
  echo
  echo "Bundled dylibs:"
  find "$BUNDLE_ROOT/lib" -maxdepth 1 -type f | sort
  echo
  echo "Binary dependency report:"
  for binary in "$BUNDLE_ROOT"/bin/*; do
    echo "## $(basename "$binary")"
    otool -L "$binary"
    echo
  done
  echo "Dylib dependency report:"
  for dylib in "$BUNDLE_ROOT"/lib/*; do
    echo "## $(basename "$dylib")"
    otool -L "$dylib"
    echo
  done
} > "$MANIFEST_PATH"

(
  cd "$BUNDLE_ROOT"
  zip -qry -y "$ZIP_PATH" bin lib
)

log "Created FFmpeg CLI bundle: $ZIP_PATH"

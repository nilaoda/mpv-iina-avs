#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ffmpeg="$WORK_ROOT/ffmpeg-cli-bundle/bin/ffmpeg"
ffprobe="$WORK_ROOT/ffmpeg-cli-bundle/bin/ffprobe"
require_cmd lipo grep
"$ffmpeg" -version | grep -F "ffmpeg version $FFMPEG_VERSION "
for binary in "$ffmpeg" "$ffprobe"; do
  lipo "$binary" -verify_arch "$TARGET_ARCH"
done

decoders="$("$ffmpeg" -hide_banner -decoders 2>/dev/null)"
for codec in cavs libdavs2 libuavs3d libdra libarcdav3a; do
  if [[ "$codec" == libdavs2 && "$LICENSE_FLAVOR" != gpl ]]; then
    continue
  fi
  printf '%s\n' "$decoders" | grep -Eq "^[[:space:]]+[A-Z.]{6}[[:space:]]+$codec[[:space:]]"
done

smoke_root="$WORK_ROOT/media-stack-smoke"
mkdir -p "$smoke_root"
"$ffmpeg" -hide_banner -v error -f lavfi -i 'testsrc2=size=320x180:rate=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 1 \
  -c:v mpeg4 -c:a flac -y "$smoke_root/sdr.mkv"
"$ffmpeg" -hide_banner -v error -i "$smoke_root/sdr.mkv" -f null -
"$ffmpeg" -hide_banner -v error -i "$smoke_root/sdr.mkv" -frames:v 1 \
  -c:v libsvtav1 -svtav1-params avif=1 -y "$smoke_root/screenshot.avif"
"$ffprobe" -v error -show_entries stream=codec_name -of csv=p=0 \
  "$smoke_root/screenshot.avif" | grep -Fx av1

# 使用同一套 AV3A 回归验证内容探测、跨包解析和无节目表 TS。
printf '#include "verify_av3a.h"\nint main(void) { return verify_av3a(); }\n' > "$smoke_root/verify_av3a.c"
clang -arch "$TARGET_ARCH" -O2 -Wall -Wextra -DAV3A_VERIFY_DCA3 -I"$SCRIPT_DIR" -I"$FFMPEG_PREFIX/include" \
  "$smoke_root/verify_av3a.c" -L"$FFMPEG_PREFIX/lib" -lavformat -lavcodec -lavutil \
  -o "$smoke_root/verify_av3a"
"$smoke_root/verify_av3a"

log "Validated $TARGET_ARCH FFmpeg $FFMPEG_VERSION, custom decoders, and AVIF encoding"

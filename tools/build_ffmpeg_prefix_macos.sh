#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_cmd curl git cmake make patch clang pkg-config install_name_tool otool python3

case "$LICENSE_FLAVOR" in
  gpl|lgpl)
    ;;
  *)
    echo "Unsupported LICENSE_FLAVOR: $LICENSE_FLAVOR" >&2
    exit 1
    ;;
esac

fetch_git_ref() {
  local url="$1"
  local ref="$2"
  local dest="$3"

  rm -rf "$dest"
  git init "$dest" >/dev/null
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch --depth 1 origin "$ref" || git -C "$dest" fetch origin "$ref"
  git -C "$dest" checkout --detach FETCH_HEAD >/dev/null
}

apply_local_davs2_macos_perf_tweaks() {
  local configure_file="$1"
  python3 - "$configure_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(errors='ignore')
original = text

text = text.replace(
    "if cc_check '' -fno-tree-vectorize ; then\n    CFLAGS=\"$CFLAGS -fno-tree-vectorize\"\nfi",
    "if [ \"$ARCH\" != \"AARCH64\" ] && [ \"$ARCH\" != \"ARM\" ] && cc_check '' -fno-tree-vectorize ; then\n    CFLAGS=\"$CFLAGS -fno-tree-vectorize\"\nfi"
)

if text == original:
  raise SystemExit('local davs2 macOS perf tweak did not match expected configure patterns')

path.write_text(text)
print(f'patched {path}')
PY
}


UAVS3D_GIT_URL="https://github.com/uavs3/uavs3d.git"
UAVS3D_GIT_REF="${UAVS3D_GIT_REF:-0e20d2c291853f196c68922a264bcd8471d75b68}"
DAVS2_GIT_URL="https://github.com/xatabhk/davs2-10bit.git"
DAVS2_GIT_REF="${DAVS2_GIT_REF:-21d64c8f8e36af71fc7a488cd6f789c86cdd1200}"
UAVS3D_SOURCE_DIR="$SOURCE_ROOT/uavs3d"
UAVS3D_BUILD_DIR="$UAVS3D_SOURCE_DIR/build/cmake"
UAVS3D_INSTALL_ROOT="$WORK_ROOT/uavs3d-install"
DAVS2_SOURCE_DIR="$SOURCE_ROOT/davs2"
DAVS2_BUILD_DIR="$DAVS2_SOURCE_DIR/build"
DAVS2_INSTALL_ROOT="$WORK_ROOT/davs2-install"
LOCAL_PATCH_ROOT="${LOCAL_PATCH_ROOT:-$SCRIPT_DIR/patches}"
DAVS2_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch"
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  DAVS2_EXTRA_CFLAGS_DEFAULT="-mcpu=apple-m1 -fvectorize -fslp-vectorize"
  DAVS2_EXTRA_LDFLAGS_DEFAULT=""
else
  DAVS2_EXTRA_CFLAGS_DEFAULT=""
  DAVS2_EXTRA_LDFLAGS_DEFAULT=""
fi
DAVS2_EFFECTIVE_EXTRA_CFLAGS="${DAVS2_EXTRA_CFLAGS:-$DAVS2_EXTRA_CFLAGS_DEFAULT}"
DAVS2_EFFECTIVE_EXTRA_LDFLAGS="${DAVS2_EXTRA_LDFLAGS:-$DAVS2_EXTRA_LDFLAGS_DEFAULT}"
FFMPEG_DAVS2_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0001-libdavs2-export-pkt_pos-from-decoder-output.patch"
FFMPEG_CAVS_DRA_MACOS_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0002-libcavs-fix-macos-build-compat.patch"
FFMPEG_CAVS_DRA_FIELD_ORDER_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0003-libcavs-preserve-field-order-and-output-flags.patch"
DEFAULT_CAVS_DRA_PATCH_PATH="${DEFAULT_CAVS_DRA_PATCH_PATH:-}"
CAVS_DRA_GIT_URL="https://github.com/maliwen2015/ffmpeg_cavs_dra.git"
CAVS_DRA_GIT_REF="${CAVS_DRA_GIT_REF:-abae276fed97ce08928f25c8f5e03fd915687f54}"
CAVS_DRA_SOURCE_DIR="$SOURCE_ROOT/ffmpeg_cavs_dra"
CAVS_DRA_PATCH_CACHE_PATH="$CAVS_DRA_SOURCE_DIR/ffmpeg-7.1.2_cavs_dra.patch"
FFMPEG_CAVS_DRA_PATCH_PATH="${FFMPEG_CAVS_DRA_PATCH_PATH:-}"
ENABLE_LIBDAVS2=false
SOURCE_BASENAME="ffmpeg-$FFMPEG_VERSION"
SOURCE_ARCHIVE="$SOURCE_ROOT/$SOURCE_BASENAME.tar.xz"
SOURCE_URL="https://ffmpeg.org/releases/$SOURCE_BASENAME.tar.xz"
SOURCE_DIR="$SOURCE_ROOT/$SOURCE_BASENAME"

log "Preparing FFmpeg source"
mkdir -p "$SOURCE_ROOT"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl -L "$SOURCE_URL" -o "$SOURCE_ARCHIVE"
fi
rm -rf "$SOURCE_DIR"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"
rm -rf "$FFMPEG_PREFIX" "$UAVS3D_INSTALL_ROOT" "$UAVS3D_SOURCE_DIR" "$DAVS2_INSTALL_ROOT" "$DAVS2_SOURCE_DIR"
mkdir -p "$FFMPEG_PREFIX" "$UAVS3D_INSTALL_ROOT"

log "Building libuavs3d"
fetch_git_ref "$UAVS3D_GIT_URL" "$UAVS3D_GIT_REF" "$UAVS3D_SOURCE_DIR"
cmake -S "$UAVS3D_SOURCE_DIR" \
  -B "$UAVS3D_BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_INSTALL_PREFIX="$UAVS3D_INSTALL_ROOT" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCOMPILE_10BIT=1
cmake --build "$UAVS3D_BUILD_DIR" -j"$CPU_COUNT"
cmake --install "$UAVS3D_BUILD_DIR"

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/libuavs3d.a" ]]; then
  echo "Static libuavs3d archive was not produced" >&2
  exit 1
fi

if find "$UAVS3D_INSTALL_ROOT/lib" -maxdepth 1 -name 'libuavs3d*.dylib' | grep -q .; then
  echo "Dynamic libuavs3d artifacts were produced unexpectedly" >&2
  exit 1
fi

if [[ ! -f "$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" ]]; then
  mkdir -p "$UAVS3D_INSTALL_ROOT/lib/pkgconfig"
  cat > "$UAVS3D_INSTALL_ROOT/lib/pkgconfig/uavs3d.pc" <<PC
prefix=$UAVS3D_INSTALL_ROOT
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: uavs3d
Description: AVS3 decoder library
Version: 1.1.41
Libs: -L\${libdir} -luavs3d
Cflags: -I\${includedir}
PC
fi

if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  ENABLE_LIBDAVS2=true

  log "Building libdavs2"
  fetch_git_ref "$DAVS2_GIT_URL" "$DAVS2_GIT_REF" "$DAVS2_SOURCE_DIR"

  if ! git -C "$DAVS2_SOURCE_DIR" apply --check "$DAVS2_PATCH_PATH"; then
    git -C "$DAVS2_SOURCE_DIR" apply --check --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH"
  fi
  if ! git -C "$DAVS2_SOURCE_DIR" apply "$DAVS2_PATCH_PATH"; then
    git -C "$DAVS2_SOURCE_DIR" apply --ignore-space-change --ignore-whitespace "$DAVS2_PATCH_PATH"
  fi

  log "Applying local davs2 macOS perf tweaks"
  apply_local_davs2_macos_perf_tweaks "$DAVS2_SOURCE_DIR/build/linux/configure"

  DAVS2_CONFIGURE_DIR=""
  while IFS= read -r configure_path; do
    DAVS2_CONFIGURE_DIR="$(dirname "$configure_path")"
    break
  done < <(find "$DAVS2_BUILD_DIR" -maxdepth 2 -type f -name configure | sort)

  if [[ -z "$DAVS2_CONFIGURE_DIR" ]]; then
    echo "Could not locate davs2 configure script under $DAVS2_BUILD_DIR" >&2
    exit 1
  fi

  pushd "$DAVS2_CONFIGURE_DIR" >/dev/null
  davs2_configure_args=(
    --host=aarch64-apple-darwin
    --prefix="$DAVS2_INSTALL_ROOT"
    --disable-cli
    --enable-pic
    --bit-depth=10
  )
  if [[ -n "$DAVS2_EFFECTIVE_EXTRA_CFLAGS" ]]; then
    davs2_configure_args+=("--extra-cflags=$DAVS2_EFFECTIVE_EXTRA_CFLAGS")
  fi
  if [[ -n "$DAVS2_EFFECTIVE_EXTRA_LDFLAGS" ]]; then
    davs2_configure_args+=("--extra-ldflags=$DAVS2_EFFECTIVE_EXTRA_LDFLAGS")
  fi
  if ! CC=clang CXX=clang++ ./configure "${davs2_configure_args[@]}"; then
    if [[ -f config.log ]]; then
      echo "===== davs2 config.log (tail 400) =====" >&2
      tail -n 400 config.log >&2
    fi
    exit 1
  fi
  make -j"$CPU_COUNT"
  make install-lib-static
  popd >/dev/null

  DAVS2_PKG_CONFIG_FILE="$DAVS2_INSTALL_ROOT/lib/pkgconfig/davs2.pc"
  mkdir -p "$(dirname "$DAVS2_PKG_CONFIG_FILE")"
  cat > "$DAVS2_PKG_CONFIG_FILE" <<PC
prefix=$DAVS2_INSTALL_ROOT
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: davs2
Description: AVS2 (IEEE 1857.4) decoder library
Version: 1.6.0
Libs: -L\${libdir} -ldavs2 -lc++ -lpthread
Cflags: -I\${includedir}
PC

  DAVS2_PKG_VERSION="$(PKG_CONFIG_PATH="$DAVS2_INSTALL_ROOT/lib/pkgconfig" "$PKG_CONFIG_BIN" --modversion davs2 || true)"
  echo "Detected davs2 pkg-config version: ${DAVS2_PKG_VERSION:-unknown}"
  if ! PKG_CONFIG_PATH="$DAVS2_INSTALL_ROOT/lib/pkgconfig" "$PKG_CONFIG_BIN" --exists 'davs2 >= 1.6.0'; then
    echo "davs2 pkg-config version requirement (>= 1.6.0) is not satisfied" >&2
    exit 1
  fi

  if [[ ! -f "$DAVS2_INSTALL_ROOT/lib/libdavs2.a" ]]; then
    echo "Static libdavs2 archive was not produced" >&2
    exit 1
  fi
  if find "$DAVS2_INSTALL_ROOT/lib" -maxdepth 1 -name 'libdavs2*.dylib' | grep -q .; then
    echo "Dynamic libdavs2 artifacts were produced unexpectedly" >&2
    exit 1
  fi
fi

log "Applying FFmpeg compatibility patches"
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  if [[ ! -f "$FFMPEG_DAVS2_PATCH_PATH" ]]; then
    echo "Missing FFmpeg davs2 patch file: $FFMPEG_DAVS2_PATCH_PATH" >&2
    exit 1
  fi
  if ! patch -d "$SOURCE_DIR" -p1 --forward < "$FFMPEG_DAVS2_PATCH_PATH"; then
    patch -d "$SOURCE_DIR" -p1 --forward -l < "$FFMPEG_DAVS2_PATCH_PATH"
  fi
fi

if [[ -z "$FFMPEG_CAVS_DRA_PATCH_PATH" ]]; then
  if [[ -n "$DEFAULT_CAVS_DRA_PATCH_PATH" && -f "$DEFAULT_CAVS_DRA_PATCH_PATH" ]]; then
    FFMPEG_CAVS_DRA_PATCH_PATH="$DEFAULT_CAVS_DRA_PATCH_PATH"
  else
    fetch_git_ref "$CAVS_DRA_GIT_URL" "$CAVS_DRA_GIT_REF" "$CAVS_DRA_SOURCE_DIR"
    FFMPEG_CAVS_DRA_PATCH_PATH="$CAVS_DRA_PATCH_CACHE_PATH"
  fi
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra patch file: $FFMPEG_CAVS_DRA_PATCH_PATH" >&2
  exit 1
fi
if ! git -C "$SOURCE_DIR" apply -p2 --check "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
  if ! git -C "$SOURCE_DIR" apply -p2 --check --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
    echo "Failed to validate FFmpeg cavs/dra patch against ffmpeg-$FFMPEG_VERSION" >&2
    exit 1
  fi
fi
if ! git -C "$SOURCE_DIR" apply -p2 "$FFMPEG_CAVS_DRA_PATCH_PATH" 2>/dev/null; then
  git -C "$SOURCE_DIR" apply -p2 --recount --ignore-space-change --ignore-whitespace "$FFMPEG_CAVS_DRA_PATCH_PATH"
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra macOS patch file: $FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" >&2
  exit 1
fi
if ! patch -d "$SOURCE_DIR" -p1 --batch --forward -N -l < "$FFMPEG_CAVS_DRA_MACOS_PATCH_PATH"; then
  echo "Failed to apply FFmpeg cavs/dra macOS patch: $FFMPEG_CAVS_DRA_MACOS_PATCH_PATH" >&2
  exit 1
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_FIELD_ORDER_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra field-order patch file: $FFMPEG_CAVS_DRA_FIELD_ORDER_PATCH_PATH" >&2
  exit 1
fi
if ! patch -d "$SOURCE_DIR" -p1 --batch --forward -N -l < "$FFMPEG_CAVS_DRA_FIELD_ORDER_PATCH_PATH"; then
  echo "Failed to apply FFmpeg cavs/dra field-order patch: $FFMPEG_CAVS_DRA_FIELD_ORDER_PATCH_PATH" >&2
  exit 1
fi

PKG_CONFIG_PATH_ENTRIES=("$UAVS3D_INSTALL_ROOT/lib/pkgconfig")
CPPFLAGS_ENTRIES=("-I$UAVS3D_INSTALL_ROOT/include")
LDFLAGS_ENTRIES=("-L$UAVS3D_INSTALL_ROOT/lib")
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  PKG_CONFIG_PATH_ENTRIES+=("$DAVS2_INSTALL_ROOT/lib/pkgconfig")
  CPPFLAGS_ENTRIES+=("-I$DAVS2_INSTALL_ROOT/include")
  LDFLAGS_ENTRIES+=("-L$DAVS2_INSTALL_ROOT/lib")
fi
export PKG_CONFIG_PATH="$(join_by : "${PKG_CONFIG_PATH_ENTRIES[@]}")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="$(join_by ' ' "${CPPFLAGS_ENTRIES[@]}")${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="$(join_by ' ' "${LDFLAGS_ENTRIES[@]}")${LDFLAGS:+ $LDFLAGS}"

log "Configuring FFmpeg"
pushd "$SOURCE_DIR" >/dev/null
CONFIGURE_FLAGS=(
  --prefix="$FFMPEG_PREFIX"
  --arch="$TARGET_ARCH"
  --target-os=darwin
  --cc=clang
  --pkg-config="$PKG_CONFIG_BIN"
  --enable-shared
  --enable-pthreads
  --disable-static
  --disable-doc
  --disable-debug
  --enable-pic
  --enable-videotoolbox
  --enable-audiotoolbox
  --enable-neon
  --enable-sdl2
  --enable-ffplay
)
if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  CONFIGURE_FLAGS+=(--enable-gpl --enable-version3)
fi
CONFIGURE_FLAGS+=(--enable-libuavs3d)
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  CONFIGURE_FLAGS+=(--enable-libdavs2)
fi

if ! ./configure "${CONFIGURE_FLAGS[@]}"; then
  if [[ -f ffbuild/config.log ]]; then
    echo "===== ffbuild/config.log (tail 400) =====" >&2
    tail -n 400 ffbuild/config.log >&2
  else
    echo "ffbuild/config.log was not generated" >&2
  fi
  exit 1
fi
make -j"$CPU_COUNT"
make install
popd >/dev/null

log "Writing FFmpeg build manifest"
cat > "$ARTIFACT_ROOT/ffmpeg-prefix-manifest.txt" <<MANIFEST
FFmpeg version: $FFMPEG_VERSION
License flavor: $LICENSE_FLAVOR
Target arch: $TARGET_ARCH
Built davs2: $ENABLE_LIBDAVS2
FFmpeg prefix: $FFMPEG_PREFIX
Patch root: $LOCAL_PATCH_ROOT
Davs2 extra cflags: ${DAVS2_EFFECTIVE_EXTRA_CFLAGS:-<none>}
Davs2 extra ldflags: ${DAVS2_EFFECTIVE_EXTRA_LDFLAGS:-<none>}
Configure flags:
$(printf '  %s\n' "${CONFIGURE_FLAGS[@]}")
MANIFEST

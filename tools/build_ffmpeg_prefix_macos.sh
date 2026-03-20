#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_cmd curl git cmake make patch clang pkg-config install_name_tool otool libtool

case "$LICENSE_FLAVOR" in
  gpl|lgpl)
    ;;
  *)
    echo "Unsupported LICENSE_FLAVOR: $LICENSE_FLAVOR" >&2
    exit 1
    ;;
esac

resolve_tool_path() {
  local env_name="$1"
  local xcrun_name="$2"
  local fallback_name="$3"
  local value="${!env_name:-}"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if command -v xcrun >/dev/null 2>&1; then
    value="$(xcrun --find "$xcrun_name" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi

  command -v "$fallback_name"
}

CC_BIN="$(resolve_tool_path CC clang clang)"
CXX_BIN="$(resolve_tool_path CXX clang++ clang++)"
AR_BIN="$(resolve_tool_path AR ar ar)"
RANLIB_BIN="$(resolve_tool_path RANLIB ranlib ranlib)"
STRIP_BIN="$(resolve_tool_path STRIP strip strip)"
LIBTOOL_BIN="$(resolve_tool_path LIBTOOL libtool libtool)"

for tool_path in "$CC_BIN" "$CXX_BIN" "$AR_BIN" "$RANLIB_BIN" "$STRIP_BIN" "$LIBTOOL_BIN"; do
  if [[ ! -x "$tool_path" ]]; then
    echo "Required tool is not executable: $tool_path" >&2
    exit 1
  fi
done

export CC="$CC_BIN"
export CXX="$CXX_BIN"
export AR="$AR_BIN"
export RANLIB="$RANLIB_BIN"
export STRIP="$STRIP_BIN"
export LIBTOOL="$LIBTOOL_BIN"

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

apply_patch_with_fallback() {
  local target_dir="$1"
  local patch_path="$2"

  if git -C "$target_dir" apply --check --recount --ignore-space-change --ignore-whitespace "$patch_path" >/dev/null 2>&1; then
    git -C "$target_dir" apply --recount --ignore-space-change --ignore-whitespace "$patch_path"
    return 0
  fi

  patch -d "$target_dir" -p1 --batch --forward -N -l < "$patch_path"
}

clang_supports_arm64_flag() {
  local flag="$1"
  local tmp_obj
  tmp_obj="$(mktemp "${TMPDIR:-/tmp}/davs2-arm64-flag-check.XXXXXX.o")"
  if printf 'int main(void) { return 0; }\n' | "$CC_BIN" -arch arm64 -x c -c -o "$tmp_obj" - "$flag" >/dev/null 2>&1; then
    rm -f "$tmp_obj"
    return 0
  fi
  rm -f "$tmp_obj"
  return 1
}

resolve_arm64_mcpu_flag() {
  local requested_mcpu="${1:-auto}"
  local effective_mcpu=""

  case "$requested_mcpu" in
    auto)
      for candidate in "-mcpu=native" "-mcpu=apple-m4" "-mcpu=apple-m3" "-mcpu=apple-m2" "-mcpu=apple-m1"; do
        if clang_supports_arm64_flag "$candidate"; then
          effective_mcpu="$candidate"
          break
        fi
      done
      ;;
    none|'')
      effective_mcpu=""
      ;;
    *)
      effective_mcpu="-mcpu=$requested_mcpu"
      ;;
  esac

  printf '%s' "$effective_mcpu"
}

resolve_apple_silicon_extra_cflags_default() {
  local requested_mcpu="${1:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}"
  local effective_mcpu=""
  local -a flags=()

  effective_mcpu="$(resolve_arm64_mcpu_flag "$requested_mcpu")"
  if [[ -n "$effective_mcpu" ]]; then
    flags+=("$effective_mcpu")
  fi
  flags+=("-fvectorize" "-fslp-vectorize")

  join_by ' ' "${flags[@]}"
}

resolve_apple_silicon_extra_asmflags_default() {
  local requested_mcpu="${1:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}"

  resolve_arm64_mcpu_flag "$requested_mcpu"
}

resolve_davs2_arm64_extra_cflags_default() {
  local requested_mcpu="${DAVS2_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}"
  local effective_mcpu=""
  local -a flags=()

  effective_mcpu="$(resolve_arm64_mcpu_flag "$requested_mcpu")"
  if [[ -n "$effective_mcpu" ]]; then
    flags+=("$effective_mcpu")
  fi
  flags+=("-fvectorize" "-fslp-vectorize")
  if [[ "${DAVS2_ENABLE_THINLTO:-0}" == "1" ]]; then
    flags+=("-flto=thin")
  fi

  join_by ' ' "${flags[@]}"
}

resolve_davs2_arm64_extra_ldflags_default() {
  local -a flags=()

  if [[ "${DAVS2_ENABLE_THINLTO:-0}" == "1" ]]; then
    flags+=("-flto=thin")
  fi

  if (( ${#flags[@]} == 0 )); then
    printf ''
    return 0
  fi

  join_by ' ' "${flags[@]}"
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
AV3A_GIT_URL="${AV3A_GIT_URL:-https://github.com/nilaoda/Sourcecodeforplayer}"
AV3A_GIT_REF="${AV3A_GIT_REF:-e7d244d29454eb04c968cd98a30587303a9c15f8}"
AV3A_SOURCE_DIR="$SOURCE_ROOT/av3a"
AV3A_BUILD_ROOT="$WORK_ROOT/av3a-build"
AV3A_INSTALL_ROOT="$WORK_ROOT/av3a-install"
AV3A_DECODER_SOURCE_DIR="$AV3A_SOURCE_DIR/av3adecoder"
AV3A_RENDER_SOURCE_DIR="$AV3A_SOURCE_DIR/av3a_binaural_render/AudioDecoder/av3a_binaural_render"
LOCAL_PATCH_ROOT="${LOCAL_PATCH_ROOT:-$SCRIPT_DIR/patches}"
DAVS2_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch"
DAVS2_ARM64_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0002-enable-arm64-neon-detect-and-keep-vectorization.patch"
DAVS2_ARM64_PRIMITIVES_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0003-add-aarch64-neon-primitives-for-copy-add-avg.patch"
DAVS2_ARM64_MC_INTERP_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0004-add-aarch64-neon-mc-interpolation.patch"
DAVS2_ARM64_MC_EXT_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0005-add-aarch64-neon-mc-ext-primitives.patch"
DAVS2_ARM64_DEBLOCK_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0006-add-aarch64-neon-deblock-luma.patch"
DAVS2_ARM64_DEBLOCK_CHROMA_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0007-add-aarch64-neon-deblock-chroma.patch"
DAVS2_ARM64_INTRA_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0008-add-aarch64-neon-intra-basic-10bit.patch"
DAVS2_ARM64_INTRA_BILINEAR_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0009-add-aarch64-neon-intra-bilinear-10bit.patch"
DAVS2_SEQ_DISPLAY_COLOR_PATCH_PATH="$LOCAL_PATCH_ROOT/davs2-10bit/0010-export-sequence-display-color-description.patch"
DAVS2_ENABLE_EXPERIMENTAL_MC_INTERP="${DAVS2_ENABLE_EXPERIMENTAL_MC_INTERP:-1}"
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  FFMPEG_EXTRA_CFLAGS_DEFAULT="$(resolve_apple_silicon_extra_cflags_default "${FFMPEG_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}")"
  FFMPEG_EXTRA_CXXFLAGS_DEFAULT="$FFMPEG_EXTRA_CFLAGS_DEFAULT"
  UAVS3D_EXTRA_CFLAGS_DEFAULT="$(resolve_apple_silicon_extra_cflags_default "${UAVS3D_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}")"
  UAVS3D_EXTRA_CXXFLAGS_DEFAULT="$UAVS3D_EXTRA_CFLAGS_DEFAULT"
  UAVS3D_EXTRA_ASMFLAGS_DEFAULT="$(resolve_apple_silicon_extra_asmflags_default "${UAVS3D_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}")"
  AV3A_EXTRA_CFLAGS_DEFAULT="$(resolve_apple_silicon_extra_cflags_default "${AV3A_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}")"
  AV3A_EXTRA_CXXFLAGS_DEFAULT="$(resolve_apple_silicon_extra_cflags_default "${AV3A_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}")"
  DAVS2_EXTRA_CFLAGS_DEFAULT="$(resolve_davs2_arm64_extra_cflags_default)"
  DAVS2_EXTRA_LDFLAGS_DEFAULT="$(resolve_davs2_arm64_extra_ldflags_default)"
else
  FFMPEG_EXTRA_CFLAGS_DEFAULT=""
  FFMPEG_EXTRA_CXXFLAGS_DEFAULT=""
  UAVS3D_EXTRA_CFLAGS_DEFAULT=""
  UAVS3D_EXTRA_CXXFLAGS_DEFAULT=""
  UAVS3D_EXTRA_ASMFLAGS_DEFAULT=""
  AV3A_EXTRA_CFLAGS_DEFAULT=""
  AV3A_EXTRA_CXXFLAGS_DEFAULT=""
  DAVS2_EXTRA_CFLAGS_DEFAULT=""
  DAVS2_EXTRA_LDFLAGS_DEFAULT=""
fi
FFMPEG_EFFECTIVE_EXTRA_CFLAGS="${FFMPEG_EXTRA_CFLAGS:-$FFMPEG_EXTRA_CFLAGS_DEFAULT}"
FFMPEG_EFFECTIVE_EXTRA_CXXFLAGS="${FFMPEG_EXTRA_CXXFLAGS:-$FFMPEG_EXTRA_CXXFLAGS_DEFAULT}"
UAVS3D_EFFECTIVE_EXTRA_CFLAGS="${UAVS3D_EXTRA_CFLAGS-$UAVS3D_EXTRA_CFLAGS_DEFAULT}"
UAVS3D_EFFECTIVE_EXTRA_CXXFLAGS="${UAVS3D_EXTRA_CXXFLAGS-$UAVS3D_EXTRA_CXXFLAGS_DEFAULT}"
UAVS3D_EFFECTIVE_EXTRA_ASMFLAGS="${UAVS3D_EXTRA_ASMFLAGS-$UAVS3D_EXTRA_ASMFLAGS_DEFAULT}"
AV3A_EFFECTIVE_EXTRA_CFLAGS="${AV3A_EXTRA_CFLAGS:-$AV3A_EXTRA_CFLAGS_DEFAULT}"
AV3A_EFFECTIVE_EXTRA_CXXFLAGS="${AV3A_EXTRA_CXXFLAGS:-$AV3A_EXTRA_CXXFLAGS_DEFAULT}"
DAVS2_EFFECTIVE_EXTRA_CFLAGS="${DAVS2_EXTRA_CFLAGS:-$DAVS2_EXTRA_CFLAGS_DEFAULT}"
DAVS2_EFFECTIVE_EXTRA_LDFLAGS="${DAVS2_EXTRA_LDFLAGS:-$DAVS2_EXTRA_LDFLAGS_DEFAULT}"
FFMPEG_CAVS_DRA_BASE_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0001-libcavs-add-avs-avsplus-dra-base.patch"
FFMPEG_DAVS2_COLOR_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0002-libdavs2-export-sequence-display-color-metadata.patch"
FFMPEG_AV3A_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0003-libarcdav3a-add-av3a-audio-vivid-decoder.patch"
FFMPEG_AV3A_FORMAT_PATCH_PATH="$LOCAL_PATCH_ROOT/ffmpeg/0004-av3a-container-parser-demux.patch"
DAVS2_CONFIGURE_HOST="${DAVS2_CONFIGURE_HOST:-aarch64-apple-darwin}"
ENABLE_LIBDAVS2=false
ENABLE_LIBARCDAV3A=false
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
git init "$SOURCE_DIR" >/dev/null
rm -rf "$FFMPEG_PREFIX" "$UAVS3D_INSTALL_ROOT" "$UAVS3D_SOURCE_DIR" "$DAVS2_INSTALL_ROOT" "$DAVS2_SOURCE_DIR"
rm -rf "$AV3A_INSTALL_ROOT" "$AV3A_SOURCE_DIR" "$AV3A_BUILD_ROOT"
mkdir -p "$FFMPEG_PREFIX" "$UAVS3D_INSTALL_ROOT" "$AV3A_INSTALL_ROOT"

log "Building libuavs3d"
fetch_git_ref "$UAVS3D_GIT_URL" "$UAVS3D_GIT_REF" "$UAVS3D_SOURCE_DIR"
uavs3d_cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DCMAKE_INSTALL_PREFIX="$UAVS3D_INSTALL_ROOT"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCOMPILE_10BIT=1
)
if [[ -n "$UAVS3D_EFFECTIVE_EXTRA_CFLAGS" ]]; then
  uavs3d_cmake_args+=(-DCMAKE_C_FLAGS="$UAVS3D_EFFECTIVE_EXTRA_CFLAGS")
fi
if [[ -n "$UAVS3D_EFFECTIVE_EXTRA_CXXFLAGS" ]]; then
  uavs3d_cmake_args+=(-DCMAKE_CXX_FLAGS="$UAVS3D_EFFECTIVE_EXTRA_CXXFLAGS")
fi
if [[ -n "$UAVS3D_EFFECTIVE_EXTRA_ASMFLAGS" ]]; then
  uavs3d_cmake_args+=(-DCMAKE_ASM_FLAGS="$UAVS3D_EFFECTIVE_EXTRA_ASMFLAGS")
fi
cmake -S "$UAVS3D_SOURCE_DIR" \
  -B "$UAVS3D_BUILD_DIR" \
  "${uavs3d_cmake_args[@]}"
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

log "Preparing AV3A sources"
if [[ -z "$AV3A_GIT_URL" ]]; then
  echo "Missing AV3A_GIT_URL." >&2
  exit 1
fi
fetch_git_ref "$AV3A_GIT_URL" "${AV3A_GIT_REF:-HEAD}" "$AV3A_SOURCE_DIR"

log "Building AVS3 audio decoder (libAVS3AudioDec)"
AV3A_DECODER_BUILD_DIR="$AV3A_BUILD_ROOT/avs3decoder"
mkdir -p "$AV3A_DECODER_BUILD_DIR" "$AV3A_INSTALL_ROOT/lib"
av3a_decoder_cflags=(-O3 -fPIC -std=c99 -Dmain=avs3_decoder_main)
append_flags_from_env AV3A_EFFECTIVE_EXTRA_CFLAGS av3a_decoder_cflags
if [[ "$TARGET_ARCH" == "arm64" ]]; then
  av3a_decoder_cflags+=(-DARCH_AARCH64 -DSUPPORT_NEON -fsigned-char)
fi
av3a_decoder_includes=(
  "-I$AV3A_DECODER_SOURCE_DIR/avs3Decoder/include"
  "-I$AV3A_DECODER_SOURCE_DIR/avs3Decoder/src"
  "-I$AV3A_DECODER_SOURCE_DIR/libavs3_common"
  "-I$AV3A_DECODER_SOURCE_DIR/libavs3_debug"
)
av3a_decoder_sources=()
while IFS= read -r src; do
  av3a_decoder_sources+=("$src")
done < <(find "$AV3A_DECODER_SOURCE_DIR/avs3Decoder/src" \
  "$AV3A_DECODER_SOURCE_DIR/libavs3_common" \
  "$AV3A_DECODER_SOURCE_DIR/libavs3_debug" \
  -type f -name '*.c' | sort)
av3a_decoder_objects=()
for src in "${av3a_decoder_sources[@]}"; do
  rel="${src#$AV3A_DECODER_SOURCE_DIR/}"
  obj="$AV3A_DECODER_BUILD_DIR/${rel//\//_}.o"
  av3a_decoder_objects+=("$obj")
  "$CC_BIN" "${av3a_decoder_cflags[@]}" "${av3a_decoder_includes[@]}" -c "$src" -o "$obj"
done
"$LIBTOOL_BIN" -static -o "$AV3A_INSTALL_ROOT/lib/libAVS3AudioDec.a" "${av3a_decoder_objects[@]}"

if [[ ! -f "$AV3A_INSTALL_ROOT/lib/libAVS3AudioDec.a" ]]; then
  echo "Static libAVS3AudioDec archive was not produced" >&2
  exit 1
fi

log "Building AV3A binaural renderer (libav3a_binaural_render)"
AV3A_RENDER_BUILD_DIR="$AV3A_BUILD_ROOT/av3a-render"
mkdir -p "$AV3A_RENDER_BUILD_DIR"
av3a_render_cflags=(-O3 -fPIC -DHAVE_CONFIG_H)
av3a_render_cxxflags=(-O3 -fPIC -std=c++11 -DHAVE_CONFIG_H)
append_flags_from_env AV3A_EFFECTIVE_EXTRA_CFLAGS av3a_render_cflags
append_flags_from_env AV3A_EFFECTIVE_EXTRA_CXXFLAGS av3a_render_cxxflags
av3a_render_includes=(
  "-I$AV3A_RENDER_SOURCE_DIR"
  "-I$AV3A_RENDER_SOURCE_DIR/ext/pffft"
  "-I$AV3A_RENDER_SOURCE_DIR/ext/libsamplerate"
  "-I$AV3A_RENDER_SOURCE_DIR/ext/simd"
  "-I$AV3A_RENDER_SOURCE_DIR/ext/hrtf_database"
  "-I$AV3A_SOURCE_DIR/av3a_binaural_render/VMFFramework/bin/VMFSDK/include/PlatForm"
)
av3a_render_sources=()
while IFS= read -r src; do
  av3a_render_sources+=("$src")
done < <(find "$AV3A_RENDER_SOURCE_DIR" -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' \) \
  ! -path '*/build/*' ! -path '*/Eigen/*' | sort)
av3a_render_objects=()
for src in "${av3a_render_sources[@]}"; do
  rel="${src#$AV3A_RENDER_SOURCE_DIR/}"
  obj="$AV3A_RENDER_BUILD_DIR/${rel//\//_}.o"
  av3a_render_objects+=("$obj")
  if [[ "$src" == *.c ]]; then
    "$CC_BIN" "${av3a_render_cflags[@]}" "${av3a_render_includes[@]}" -c "$src" -o "$obj"
  else
    "$CXX_BIN" "${av3a_render_cxxflags[@]}" "${av3a_render_includes[@]}" -c "$src" -o "$obj"
  fi
done
"$LIBTOOL_BIN" -static -o "$AV3A_INSTALL_ROOT/lib/libav3a_binaural_render.a" "${av3a_render_objects[@]}"

if [[ ! -f "$AV3A_INSTALL_ROOT/lib/libav3a_binaural_render.a" ]]; then
  echo "Static libav3a_binaural_render archive was not produced" >&2
  exit 1
fi

ENABLE_LIBARCDAV3A=true

if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  ENABLE_LIBDAVS2=true

  log "Building libdavs2"
  fetch_git_ref "$DAVS2_GIT_URL" "$DAVS2_GIT_REF" "$DAVS2_SOURCE_DIR"

  davs2_patch_paths=(
    "$DAVS2_PATCH_PATH"
    "$DAVS2_ARM64_PATCH_PATH"
    "$DAVS2_ARM64_PRIMITIVES_PATCH_PATH"
  )
  if [[ "$DAVS2_ENABLE_EXPERIMENTAL_MC_INTERP" == "1" ]]; then
    davs2_patch_paths+=("$DAVS2_ARM64_MC_INTERP_PATCH_PATH")
    davs2_patch_paths+=("$DAVS2_ARM64_MC_EXT_PATCH_PATH")
    davs2_patch_paths+=("$DAVS2_ARM64_DEBLOCK_PATCH_PATH")
    davs2_patch_paths+=("$DAVS2_ARM64_DEBLOCK_CHROMA_PATCH_PATH")
    davs2_patch_paths+=("$DAVS2_ARM64_INTRA_PATCH_PATH")
    davs2_patch_paths+=("$DAVS2_ARM64_INTRA_BILINEAR_PATCH_PATH")
  fi
  davs2_patch_paths+=("$DAVS2_SEQ_DISPLAY_COLOR_PATCH_PATH")

  for patch_path in "${davs2_patch_paths[@]}"; do
    if [[ ! -f "$patch_path" ]]; then
      echo "Missing davs2 patch file: $patch_path" >&2
      exit 1
    fi
    if ! git -C "$DAVS2_SOURCE_DIR" apply --check "$patch_path"; then
      git -C "$DAVS2_SOURCE_DIR" apply --check --ignore-space-change --ignore-whitespace "$patch_path"
    fi
    if ! git -C "$DAVS2_SOURCE_DIR" apply "$patch_path"; then
      git -C "$DAVS2_SOURCE_DIR" apply --ignore-space-change --ignore-whitespace "$patch_path"
    fi
  done

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
    --host="$DAVS2_CONFIGURE_HOST"
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
  if ! CC="$CC_BIN" CXX="$CXX_BIN" AR="$AR_BIN" RANLIB="$RANLIB_BIN" ./configure "${davs2_configure_args[@]}"; then
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
  ffmpeg_davs2_patch_paths=(
    "$FFMPEG_DAVS2_COLOR_PATCH_PATH"
  )
  for patch_path in "${ffmpeg_davs2_patch_paths[@]}"; do
    if [[ ! -f "$patch_path" ]]; then
      echo "Missing FFmpeg davs2 patch file: $patch_path" >&2
      exit 1
    fi
    if ! apply_patch_with_fallback "$SOURCE_DIR" "$patch_path"; then
      echo "Failed to apply FFmpeg davs2 patch: $patch_path" >&2
      exit 1
    fi
  done
fi

if [[ ! -f "$FFMPEG_CAVS_DRA_BASE_PATCH_PATH" ]]; then
  echo "Missing FFmpeg cavs/dra base patch file: $FFMPEG_CAVS_DRA_BASE_PATCH_PATH" >&2
  exit 1
fi
if ! apply_patch_with_fallback "$SOURCE_DIR" "$FFMPEG_CAVS_DRA_BASE_PATCH_PATH"; then
  echo "Failed to apply FFmpeg cavs/dra base patch: $FFMPEG_CAVS_DRA_BASE_PATCH_PATH" >&2
  exit 1
fi

if [[ ! -f "$FFMPEG_AV3A_PATCH_PATH" ]]; then
  echo "Missing FFmpeg AV3A patch file: $FFMPEG_AV3A_PATCH_PATH" >&2
  exit 1
fi
if ! apply_patch_with_fallback "$SOURCE_DIR" "$FFMPEG_AV3A_PATCH_PATH"; then
  echo "Failed to apply FFmpeg AV3A patch: $FFMPEG_AV3A_PATCH_PATH" >&2
  exit 1
fi

if [[ ! -f "$FFMPEG_AV3A_FORMAT_PATCH_PATH" ]]; then
  echo "Missing FFmpeg AV3A format patch file: $FFMPEG_AV3A_FORMAT_PATCH_PATH" >&2
  exit 1
fi
if ! apply_patch_with_fallback "$SOURCE_DIR" "$FFMPEG_AV3A_FORMAT_PATCH_PATH"; then
  echo "Failed to apply FFmpeg AV3A format patch: $FFMPEG_AV3A_FORMAT_PATCH_PATH" >&2
  exit 1
fi

if [[ "$ENABLE_LIBARCDAV3A" == true ]]; then
  AV3A_HEADER_SRC="$SOURCE_DIR/libavcodec/arcdav3a.h"
  AV3A_HEADER_DST="$AV3A_INSTALL_ROOT/include/libavcodec"
  if [[ ! -f "$AV3A_HEADER_SRC" ]]; then
    echo "Missing AV3A header in FFmpeg source: $AV3A_HEADER_SRC" >&2
    exit 1
  fi
  mkdir -p "$AV3A_HEADER_DST"
  cp "$AV3A_HEADER_SRC" "$AV3A_HEADER_DST/"
  av3a_private_headers=()
  while IFS= read -r hdr; do
    av3a_private_headers+=("$hdr")
  done < <(find "$SOURCE_DIR/libavcodec" -maxdepth 1 -name 'avs3_*.h' -type f)
  if (( ${#av3a_private_headers[@]} == 0 )); then
    echo "No AV3A headers found under $SOURCE_DIR/libavcodec (avs3_*.h)" >&2
    exit 1
  fi
  for hdr in "${av3a_private_headers[@]}"; do
    cp "$hdr" "$AV3A_HEADER_DST/"
  done
  AV3A_COMMON_DST="$AV3A_HEADER_DST/libavs3_common"
  mkdir -p "$AV3A_COMMON_DST"
  if [[ -f "$SOURCE_DIR/libavcodec/libavs3_common/model.h" ]]; then
    cp "$SOURCE_DIR/libavcodec/libavs3_common/model.h" "$AV3A_COMMON_DST/"
  fi
fi

PKG_CONFIG_PATH_ENTRIES=("$UAVS3D_INSTALL_ROOT/lib/pkgconfig")
CPPFLAGS_ENTRIES=("-I$UAVS3D_INSTALL_ROOT/include")
LDFLAGS_ENTRIES=("-L$UAVS3D_INSTALL_ROOT/lib")
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  PKG_CONFIG_PATH_ENTRIES+=("$DAVS2_INSTALL_ROOT/lib/pkgconfig")
  CPPFLAGS_ENTRIES+=("-I$DAVS2_INSTALL_ROOT/include")
  LDFLAGS_ENTRIES+=("-L$DAVS2_INSTALL_ROOT/lib")
fi
if [[ "$ENABLE_LIBARCDAV3A" == true ]]; then
  CPPFLAGS_ENTRIES+=("-I$AV3A_INSTALL_ROOT/include")
  LDFLAGS_ENTRIES+=("-L$AV3A_INSTALL_ROOT/lib")
fi

# Keep the FFmpeg feature set aligned with IINA's official ffmpeg-iina formula where practical.
# Source: https://github.com/iina/homebrew-mpv-iina/blob/master/ffmpeg-iina.rb
ffmpeg_common_pkg_modules=(
  fontconfig
  freetype2
  gnutls
  harfbuzz
  libass
  libbluray
  libbs2b
  dav1d
  libjxl
  libplacebo
  libssh
  libwebp
  libxml-2.0
  libzmq
  rav1e
  sdl2
  soxr
  speex
  zimg
)
ffmpeg_gpl_pkg_modules=(
  frei0r
  rubberband
  vidstab
)

snappy_prefix=""
if [[ -n "${SNAPPY_PREFIX:-}" ]]; then
  snappy_prefix="$SNAPPY_PREFIX"
elif command -v brew >/dev/null 2>&1; then
  snappy_prefix="$(brew --prefix snappy 2>/dev/null || true)"
fi

libsoxr_prefix=""
if [[ -n "${LIBSOXR_PREFIX:-}" ]]; then
  libsoxr_prefix="$LIBSOXR_PREFIX"
elif command -v brew >/dev/null 2>&1; then
  libsoxr_prefix="$(brew --prefix libsoxr 2>/dev/null || true)"
fi

require_pkg_config_modules "${ffmpeg_common_pkg_modules[@]}"
if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  require_pkg_config_modules "${ffmpeg_gpl_pkg_modules[@]}"

  # Homebrew's frei0r headers live in the Cellar include dir instead of a globally linked include
  # path, while FFmpeg's configure checks for frei0r.h directly after pkg-config succeeds.
  while IFS= read -r include_flag; do
    CPPFLAGS_ENTRIES+=("$include_flag")
  done < <(append_pkg_config_flag_prefixes frei0r -I)

  while IFS= read -r include_flag; do
    CPPFLAGS_ENTRIES+=("$include_flag")
  done < <(append_pkg_config_flag_prefixes vidstab -I)

  while IFS= read -r library_flag; do
    LDFLAGS_ENTRIES+=("$library_flag")
  done < <(append_pkg_config_flag_prefixes vidstab -L)
fi

if [[ -n "$snappy_prefix" ]]; then
  if [[ -d "$snappy_prefix/include" ]]; then
    CPPFLAGS_ENTRIES+=("-I$snappy_prefix/include")
  fi
  if [[ -d "$snappy_prefix/lib" ]]; then
    LDFLAGS_ENTRIES+=("-L$snappy_prefix/lib")
  fi
fi

if [[ -n "$libsoxr_prefix" ]]; then
  if [[ -d "$libsoxr_prefix/include" ]]; then
    CPPFLAGS_ENTRIES+=("-I$libsoxr_prefix/include")
  fi
  if [[ -d "$libsoxr_prefix/lib" ]]; then
    LDFLAGS_ENTRIES+=("-L$libsoxr_prefix/lib")
  fi
fi

export PKG_CONFIG_PATH="$(join_by : "${PKG_CONFIG_PATH_ENTRIES[@]}")${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="$(join_by ' ' "${CPPFLAGS_ENTRIES[@]}")${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="$(join_by ' ' "${LDFLAGS_ENTRIES[@]}")${LDFLAGS:+ $LDFLAGS}"

log "Configuring FFmpeg"
pushd "$SOURCE_DIR" >/dev/null
log "Using Apple toolchain: CC=$CC_BIN CXX=$CXX_BIN AR=$AR_BIN RANLIB=$RANLIB_BIN STRIP=$STRIP_BIN"
CONFIGURE_FLAGS=(
  --prefix="$FFMPEG_PREFIX"
  --arch="$TARGET_ARCH"
  --target-os=darwin
  --cc="$CC_BIN"
  --pkg-config="$PKG_CONFIG_BIN"
  --enable-shared
  --enable-pthreads
  --disable-static
  --disable-doc
  --disable-debug
  --enable-pic
  --enable-gnutls
  --enable-videotoolbox
  --enable-vulkan
  --enable-audiotoolbox
  --enable-neon
  --enable-sdl2
  --enable-ffplay
  --enable-libass
  --enable-libbluray
  --enable-libbs2b
  --enable-libdav1d
  --enable-libfontconfig
  --enable-libfreetype
  --enable-libharfbuzz
  --enable-libjxl
  --enable-libplacebo
  --enable-librav1e
  --enable-libsnappy
  --enable-libsoxr
  --enable-libspeex
  --enable-libssh
  --enable-libxml2
  --enable-libwebp
  --enable-libzmq
  --enable-libzimg
  --disable-libjack
  --disable-indev=jack
  --disable-libtesseract
)
if [[ "$LICENSE_FLAVOR" == "gpl" ]]; then
  CONFIGURE_FLAGS+=(--enable-gpl --enable-version3)
  CONFIGURE_FLAGS+=(--enable-frei0r)
  CONFIGURE_FLAGS+=(--enable-librubberband)
  CONFIGURE_FLAGS+=(--enable-libvidstab)
fi
CONFIGURE_FLAGS+=(--enable-libuavs3d)
if [[ "$ENABLE_LIBARCDAV3A" == true ]]; then
  CONFIGURE_FLAGS+=(--enable-libarcdav3a)
  CONFIGURE_FLAGS+=(--extra-ldflags="-L$AV3A_INSTALL_ROOT/lib")
  CONFIGURE_FLAGS+=(--extra-libs="-lAVS3AudioDec -lav3a_binaural_render -lc++")
fi
if [[ "$ENABLE_LIBDAVS2" == true ]]; then
  CONFIGURE_FLAGS+=(--enable-libdavs2)
fi
if [[ -n "$FFMPEG_EFFECTIVE_EXTRA_CFLAGS" ]]; then
  CONFIGURE_FLAGS+=(--extra-cflags="$FFMPEG_EFFECTIVE_EXTRA_CFLAGS")
fi
if [[ -n "$FFMPEG_EFFECTIVE_EXTRA_CXXFLAGS" ]]; then
  CONFIGURE_FLAGS+=(--extra-cxxflags="$FFMPEG_EFFECTIVE_EXTRA_CXXFLAGS")
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
Built av3a: $ENABLE_LIBARCDAV3A
FFmpeg prefix: $FFMPEG_PREFIX
Patch root: $LOCAL_PATCH_ROOT
Davs2 configure host: $DAVS2_CONFIGURE_HOST
Davs2 thinlto enabled: ${DAVS2_ENABLE_THINLTO:-0}
Davs2 applemcpu override: ${DAVS2_APPLE_MCPU:-${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}}
Apple Silicon distribution mcpu: ${APPLE_SILICON_DISTRIBUTION_MCPU:-apple-m1}
FFmpeg extra cflags: ${FFMPEG_EFFECTIVE_EXTRA_CFLAGS:-<none>}
FFmpeg extra cxxflags: ${FFMPEG_EFFECTIVE_EXTRA_CXXFLAGS:-<none>}
uavs3d extra cflags: ${UAVS3D_EFFECTIVE_EXTRA_CFLAGS:-<none>}
uavs3d extra cxxflags: ${UAVS3D_EFFECTIVE_EXTRA_CXXFLAGS:-<none>}
uavs3d extra asmflags: ${UAVS3D_EFFECTIVE_EXTRA_ASMFLAGS:-<none>}
AV3A extra cflags: ${AV3A_EFFECTIVE_EXTRA_CFLAGS:-<none>}
AV3A extra cxxflags: ${AV3A_EFFECTIVE_EXTRA_CXXFLAGS:-<none>}
Davs2 extra cflags: ${DAVS2_EFFECTIVE_EXTRA_CFLAGS:-<none>}
Davs2 extra ldflags: ${DAVS2_EFFECTIVE_EXTRA_LDFLAGS:-<none>}
AV3A git url: ${AV3A_GIT_URL:-<none>}
AV3A install root: $AV3A_INSTALL_ROOT
Configure flags:
$(printf '  %s\n' "${CONFIGURE_FLAGS[@]}")
MANIFEST

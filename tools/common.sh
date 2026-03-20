#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="${WORK_ROOT:-$REPO_ROOT/.work}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$REPO_ROOT/artifacts}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
MPV_REF="${MPV_REF:-v0.41.0}"
LICENSE_FLAVOR="${LICENSE_FLAVOR:-gpl}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-pkg-config}"
CPU_COUNT="$(sysctl -n hw.ncpu)"

FFMPEG_PREFIX="${FFMPEG_PREFIX:-$WORK_ROOT/ffmpeg-prefix}"
MPV_PREFIX="${MPV_PREFIX:-$WORK_ROOT/mpv-prefix}"
SOURCE_ROOT="${SOURCE_ROOT:-$WORK_ROOT/src}"

mkdir -p "$WORK_ROOT" "$ARTIFACT_ROOT" "$SOURCE_ROOT"

log() {
  printf '==> %s\n' "$*"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Missing required command: $cmd" >&2
      exit 1
    }
  done
}

join_by() {
  local delim="$1"
  shift
  local first=1
  local item
  for item in "$@"; do
    if [[ $first -eq 1 ]]; then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$delim" "$item"
    fi
  done
}

append_flags_from_env() {
  local env_name="$1"
  local array_name="$2"
  if [[ -n "${!env_name:-}" ]]; then
    local extra
    IFS=' ' read -r -a extra <<<"${!env_name}"
    local item
    for item in "${extra[@]}"; do
      eval "$array_name+=("\$item")"
    done
  fi
}

require_pkg_config_modules() {
  local missing=()
  local module

  for module in "$@"; do
    if ! "$PKG_CONFIG_BIN" --exists "$module"; then
      missing+=("$module")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  {
    echo "Missing required pkg-config modules:"
    printf '  %s\n' "${missing[@]}"
    echo
    echo "Install the corresponding development packages first, then rerun the build."
  } >&2
  exit 1
}

append_pkg_config_flag_prefixes() {
  local module="$1"
  local prefix="$2"
  local value

  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    case "$value" in
      "$prefix"*)
        printf '%s\n' "$value"
        ;;
    esac
  done < <("$PKG_CONFIG_BIN" --cflags-only-I --libs-only-L "$module" 2>/dev/null | tr ' ' '\n')
}

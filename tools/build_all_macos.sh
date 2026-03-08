#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/build_ffmpeg_prefix_macos.sh"
"$script_dir/package_ffmpeg_cli_bundle_macos.sh"
"$script_dir/build_mpv_macos.sh"
"$script_dir/package_iina_bundle_macos.sh"

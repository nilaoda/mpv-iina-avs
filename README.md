# mpv-iina-avs

A media-stack build repository for Apple Silicon macOS, focused on producing a reproducible patched FFmpeg + libmpv dependency set for IINA / mpv with AVS / AVS+ / AVS2 / AVS3 support.

This repository now maintains its own patch stack and no longer depends on downloading patch files from `FFmpegSharedLibraries` during the build. The current approach is:

- keep using `ffmpeg-7.1.2_cavs_dra.patch` from `maliwen2015/ffmpeg_cavs_dra` as the base AVS / AVS+ / DRA enablement patch
- vendor only the additional fixes that are actually needed here under `tools/patches`
- produce two separate outputs:
  - a dylib bundle for IINA / `libmpv`
  - a relocatable FFmpeg CLI bundle for decoder and filter validation (`ffmpeg` / `ffprobe` / `ffplay`)

## Repository layout

- `README.md`
  - repository overview and build notes
- `tools/common.sh`
  - shared environment defaults, paths, and helper functions
- `tools/build_ffmpeg_prefix_macos.sh`
  - fetches and patches FFmpeg / `uavs3d` / `davs2-10bit`, then builds the FFmpeg prefix
- `tools/package_ffmpeg_cli_bundle_macos.sh`
  - packages a directly testable FFmpeg CLI bundle
- `tools/build_mpv_macos.sh`
  - builds mpv / `libmpv` against the patched FFmpeg prefix
- `tools/package_iina_bundle_macos.sh`
  - packages the `libmpv` + FFmpeg dylib set for IINA
- `tools/build_all_macos.sh`
  - runs the full FFmpeg, CLI bundle, mpv, and IINA bundle flow
- `tools/sync_bundle_to_iina.sh`
  - syncs the generated dylibs into a local IINA checkout for validation
- `tools/package_macho_bundle.rb`
  - handles Mach-O CLI bundling: binary copy, dependency collection, install-name rewriting, and re-signing
- `tools/collect_dylibs.rb`
  - collects the `libmpv` dependency set into an IINA-friendly dylib bundle
- `tools/patches/davs2-10bit/*.patch`
  - vendored `davs2-10bit` patches maintained in this repository
- `tools/patches/ffmpeg/*.patch`
  - vendored FFmpeg-side patches maintained in this repository

## Build flow

### 1. Build the FFmpeg prefix

Run:

```bash
./tools/build_ffmpeg_prefix_macos.sh
```

This script:

- downloads and extracts `ffmpeg-7.1.3`
- fetches and builds static `uavs3d`
- fetches and builds static `davs2-10bit` when `LICENSE_FLAVOR=gpl`
- applies the vendored local patches
- applies `ffmpeg_cavs_dra.patch` as the base AVS / AVS+ / DRA support patch
- installs a shared-library FFmpeg prefix for later mpv / IINA builds

Default outputs:

- FFmpeg prefix: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/.work/ffmpeg-prefix`
- source cache: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/.work/src`

### 2. Package the FFmpeg CLI bundle

Run:

```bash
./tools/package_ffmpeg_cli_bundle_macos.sh
```

This bundle is meant for direct FFmpeg behavior testing without rebuilding IINA each time. It contains:

- `ffmpeg`
- `ffprobe`
- `ffplay`
- all required FFmpeg dylibs for those executables

The packaging step also:

- preserves the versioned dylib naming / symlink behavior required by the Mach-O dependency chain
- rewrites `install_name` entries so the bundle is relocatable
- re-signs modified Mach-O binaries so macOS does not immediately kill them
- writes a dependency manifest for troubleshooting

Default output location:

- zip files: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/artifacts`
- manifest: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/artifacts/ffmpeg-cli-bundle-manifest.txt`

Note: the bundle includes `ffplay`, so runtime availability still depends on the local graphical / SDL2 environment on the target macOS system.

### 3. Build mpv / libmpv

Run:

```bash
./tools/build_mpv_macos.sh
```

This script links mpv against the patched FFmpeg prefix from the previous step and installs it into a separate mpv prefix.

Default output:

- mpv prefix: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/.work/mpv-prefix`

### 4. Package the IINA dylib bundle

Run:

```bash
./tools/package_iina_bundle_macos.sh
```

This bundle targets IINA's `deps/lib` directory and mainly contains:

- `libmpv`
- FFmpeg dylibs
- additional runtime dylibs needed by `libmpv`

Default output location:

- zip files: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/artifacts`
- manifest: `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/artifacts/iina-bundle-manifest.txt`

### 5. Run the full pipeline

Run:

```bash
./tools/build_all_macos.sh
```

Execution order:

1. `build_ffmpeg_prefix_macos.sh`
2. `package_ffmpeg_cli_bundle_macos.sh`
3. `build_mpv_macos.sh`
4. `package_iina_bundle_macos.sh`

## Patch stack

### Base patch

- `ffmpeg_cavs_dra.patch`
  - source: `https://github.com/maliwen2015/ffmpeg_cavs_dra`
  - purpose: provides the base AVS / AVS+ / DRA support for FFmpeg 7.1.x
  - this repository does not vendor that large patch directly; by default `tools/build_ffmpeg_prefix_macos.sh` fetches it during the build, but `DEFAULT_CAVS_DRA_PATCH_PATH` can point to a local copy instead

### Vendored local patches

- `tools/patches/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch`
  - enables the 10-bit build path in `davs2-10bit`
  - propagates input packet `pos` through decoder output frames
  - provides the baseline needed for FFmpeg integration instead of stopping at the original 10-bit build restriction

- `tools/patches/ffmpeg/0001-libdavs2-export-pkt_pos-from-decoder-output.patch`
  - makes FFmpeg's `libdavs2` wrapper export decoder output packet-position data onto `AVFrame`
  - keeps frame-origin metadata available for debugging and higher-level inspection

- `tools/patches/ffmpeg/0002-libcavs-fix-macos-build-compat.patch`
  - fixes `libcavs` build compatibility issues on macOS / Apple clang
  - makes the upstream `ffmpeg_cavs_dra.patch` apply cleanly and build reliably in the current macOS toolchain

- `tools/patches/ffmpeg/0003-libcavs-preserve-field-order-and-output-flags.patch`
  - fixes AVS+ interlaced output metadata handling when field order and interlaced flags were being overwritten or lost during decode output
  - specifically:
    - stops incorrectly overwriting `b_top_field_first`
    - records per-output-frame `interlaced` / `top_field_first` state on the `libcavs` output path
    - sets `AV_FRAME_FLAG_INTERLACED` and `AV_FRAME_FLAG_TOP_FIELD_FIRST` correctly in `libcavsdec`
    - uses the delayed frame's own picture structure when outputting delayed frames
  - fixes the playback issue where some 1080i AVS+ samples would stutter, oscillate, or deinterlace incorrectly

## Default environment variables

Defined in `tools/common.sh`:

- `WORK_ROOT=.work`
- `ARTIFACT_ROOT=artifacts`
- `FFMPEG_VERSION=7.1.3`
- `MPV_REF=v0.40.0`
- `LICENSE_FLAVOR=gpl`
- `TARGET_ARCH=arm64`
- `FFMPEG_PREFIX=$WORK_ROOT/ffmpeg-prefix`
- `MPV_PREFIX=$WORK_ROOT/mpv-prefix`
- `SOURCE_ROOT=$WORK_ROOT/src`

Useful overrides:

- `LOCAL_PATCH_ROOT`
  - overrides the vendored patch root; default is `tools/patches`
- `DEFAULT_CAVS_DRA_PATCH_PATH`
  - points to a local `ffmpeg_cavs_dra.patch`; if unset, the script fetches it from the upstream repository
- `DAVS2_EXTRA_CFLAGS`
  - appends extra `davs2-10bit` compiler flags; on `arm64`, the default is tuned to remain friendly to Apple Silicon vectorization
- `DAVS2_EXTRA_LDFLAGS`
  - appends extra `davs2-10bit` linker flags
- `MPV_EXTRA_MESON_FLAGS`
  - appends extra Meson flags for mpv

## Artifacts

By default, artifacts are written to `/Volumes/SSD/Windows/Github-code/mpv-iina-avs/artifacts`

Common outputs include:

- `ffmpeg-cli-bundle-macos-arm64-gpl-ffmpeg-7.1.3.zip`
  - CLI test bundle for direct AVS+ / AVS2 decoder and filter validation
- `iina-mpv-bundle-macos-arm64-gpl-ffmpeg-7.1.3-mpv-v0.40.0.zip`
  - dylib bundle for IINA / `deps/lib`
- `ffmpeg-cli-bundle-manifest.txt`
  - dependency report for the CLI bundle
- `iina-bundle-manifest.txt`
  - dependency report for the IINA dylib bundle

## GitHub Actions

The macOS workflow supports manual runs with:

- `publish_release`
  - whether to publish a GitHub Release
- `release_tag`
  - optional custom release tag

CI uses the vendored patch stack from this repository directly.

## Current status

- the Apple Silicon FFmpeg / `libmpv` / IINA dependency build is reproducible
- `davs2-10bit` builds successfully and can decode AVS2 10-bit content, though there is still room for further performance work
- the AVS+ interlaced field-order / deinterlace stutter issue is fixed in the current patch stack

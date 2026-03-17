# mpv-iina-avs

A media-stack build repository for Apple Silicon macOS, focused on producing a reproducible patched FFmpeg + libmpv dependency set for IINA / mpv with AVS / AVS+ / AVS2 / AVS3 support.

This repository maintains its own patch stack. The current approach is:

Disclaimer: Portions of the decoder source code were obtained from publicly available sources and are included solely for research and educational purposes. They are not licensed for commercial use. If you believe any content infringes your rights, please contact me and I will remove it promptly.
AV3A demuxer/parser/container handling draws from [openharmony/third_party_ffmpeg](https://github.com/openharmony/third_party_ffmpeg).

- maintain a vendored `FFmpeg 8.0.1` base patch adapted from the original `maliwen2015/ffmpeg_cavs_dra` source patch
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
  - applies local `tools/patches/mpv/*.patch` compatibility fixes before configuring mpv
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
  - vendored `davs2-10bit` patches maintained in this repository, including Apple Silicon AArch64 NEON optimizations for 10-bit decode hot paths
- `tools/patches/ffmpeg/*.patch`
  - vendored FFmpeg patch stack maintained in this repository for `FFmpeg 8.0.1`
- `tools/patches/mpv/*.patch`
  - vendored mpv compatibility patches maintained in this repository for the selected FFmpeg / mpv combination
  - vendored FFmpeg-side patches maintained in this repository

## Build flow

### 1. Build the FFmpeg prefix

Run:

```bash
./tools/build_ffmpeg_prefix_macos.sh
```

This script:

- downloads and extracts `ffmpeg-8.0.1`
- fetches and builds static `uavs3d`
- builds static AV3A decoder + binaural renderer from the local `Sourcecodeforplayer` checkout (see `AV3A_SOURCE_ROOT`)
- fetches and builds static `davs2-10bit` when `LICENSE_FLAVOR=gpl`
- applies the vendored local patches
- applies the vendored local FFmpeg patch stack, including the locally maintained AVS / AVS+ / DRA base patch derived from `maliwen2015/ffmpeg_cavs_dra`
- installs a shared-library FFmpeg prefix for later mpv / IINA builds

Default outputs:

- FFmpeg prefix: `.work/ffmpeg-prefix`
- source cache: `.work/src`

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

- zip files: `artifacts`
- manifest: `artifacts/ffmpeg-cli-bundle-manifest.txt`

Note: the bundle includes `ffplay`, so runtime availability still depends on the local graphical / SDL2 environment on the target macOS system.

### 3. Build mpv / libmpv

Run:

```bash
./tools/build_mpv_macos.sh
```

This script links mpv against the patched FFmpeg prefix from the previous step and installs it into a separate mpv prefix.
It also applies the local mpv patch stack on top of `mpv v0.41.0`, including a vendored `libmpv` `gpu-next` backend patch derived from [mpv-player/mpv#16818](https://github.com/mpv-player/mpv/pull/16818) for Dolby Vision Profile 5 experiments in IINA.

Default output:

- mpv prefix: `.work/mpv-prefix`

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

- zip files: `artifacts`
- manifest: `artifacts/iina-bundle-manifest.txt`

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

- `tools/patches/ffmpeg/0002-libcavs-add-avs-avsplus-dra-base.patch`
  - original source: `https://github.com/maliwen2015/ffmpeg_cavs_dra`
  - purpose: vendors the base AVS / AVS+ / DRA enablement patch stack directly in this repository
  - note: the patch is adapted and maintained locally for `FFmpeg 8.0.1`, so the build no longer fetches `ffmpeg_cavs_dra.patch` during execution
  - includes the macOS build-compat fixes plus the local AVS+ metadata cleanups needed for current FFmpeg
  - keeps the imported `libcavs` / `libdradec` code path usable on current Apple clang while preserving reliable progressive / interlaced output tagging

### Vendored local patches

- `tools/patches/davs2-10bit/0001-enable-10bit-build-and-propagate-frame-packet-position.patch`
  - enables the 10-bit build path in `davs2-10bit`
  - propagates input packet `pos` through decoder output frames
  - provides the baseline needed for FFmpeg integration instead of stopping at the original 10-bit build restriction

- `tools/patches/davs2-10bit/0002-enable-arm64-neon-detect-and-keep-vectorization.patch`
  - enables the Apple Silicon / `arm64` NEON detection path in `davs2-10bit`
  - keeps the build configuration friendly to compiler vectorization on AArch64
  - establishes the runtime dispatch foundation for the later NEON-specific primitives

- `tools/patches/davs2-10bit/0003-add-aarch64-neon-primitives-for-copy-add-avg.patch`
  - adds initial AArch64 NEON primitives for basic pixel copy / add / average style operations
  - reduces the cost of common low-level pixel movement and blending helpers used during motion compensation

- `tools/patches/davs2-10bit/0004-add-aarch64-neon-mc-interpolation.patch`
  - adds AArch64 NEON implementations for 10-bit luma / chroma interpolation kernels
  - covers the direct horizontal / vertical interpolation paths used by motion compensation

- `tools/patches/davs2-10bit/0005-add-aarch64-neon-mc-ext-primitives.patch`
  - adds AArch64 NEON implementations for the extended motion-compensation interpolation paths
  - accelerates the more expensive two-stage luma / chroma `*_ext` paths that combine horizontal and vertical filtering

- `tools/patches/davs2-10bit/0006-add-aarch64-neon-deblock-luma.patch`
  - adds AArch64 NEON implementations for 10-bit luma deblock filtering
  - covers both horizontal and vertical luma edge filtering paths

- `tools/patches/davs2-10bit/0007-add-aarch64-neon-deblock-chroma.patch`
  - adds AArch64 NEON implementations for 10-bit chroma deblock filtering
  - covers both horizontal and vertical chroma edge filtering paths while preserving bit-exact output

- `tools/patches/davs2-10bit/0008-add-aarch64-neon-intra-basic-10bit.patch`
  - adds AArch64 NEON implementations for the core 10-bit intra prediction modes
  - covers the common `VERT`, `HOR`, `DC`, and `PLANE` prediction paths to reduce reconstruction cost on Apple Silicon

- `tools/patches/davs2-10bit/0009-add-aarch64-neon-intra-bilinear-10bit.patch`
  - adds an AArch64 NEON implementation for the 10-bit bilinear intra prediction path
  - accelerates another frequently used intra reconstruction mode while preserving bit-exact output

- `tools/patches/davs2-10bit/0010-export-sequence-display-color-description.patch`
  - makes `davs2-10bit` parse AVS2 `sequence_display_extension` metadata and export the basic display / color-description fields through its public sequence-header output
  - propagates `sample_range`, `colour_primaries`, `transfer_characteristics`, and `matrix_coefficients` so FFmpeg can tag decoded AVS2 frames correctly

- `tools/patches/ffmpeg/0004-libdavs2-export-sequence-display-color-metadata.patch`
  - makes FFmpeg's `libdavs2` wrapper consume the additional AVS2 sequence-display metadata exported by the local `davs2-10bit` patch stack
  - maps AVS2 range / primaries / transfer / matrix values onto FFmpeg `AVCodecContext` and `AVFrame` color fields
  - allows downstream tools such as `ffmpeg`, `ffplay`, `mpv`, and IINA to recognize the basic AVS2 HDR / wide-color signalling correctly
- `tools/patches/ffmpeg/0005-libarcdav3a-add-av3a-audio-vivid-decoder.patch`
  - adds the ArcVideo `libarcdav3a` AV3A (Audio Vivid) decoder glue
- `tools/patches/ffmpeg/0006-av3a-container-parser-demux.patch`
  - adds AV3A container support (parser, demux/mux wiring, and MP4 tag mapping) for Audio Vivid streams
  - registers AV3A codec IDs, container tags, and MPEG-TS stream type mappings needed for demuxing and raw muxing
  - links against the locally built static AVS3 Audio decoder + binaural renderer (no runtime .so/.dylib dependency; model is embedded via `libavs3_common/model.h`)

- `tools/patches/ffmpeg/0007-libuavs3d-tune-apple-silicon-auto-threads.patch`
  - tunes FFmpeg's `libuavs3d` wrapper thread selection for Apple Silicon so the default auto-thread path does not underutilize the decoder
  - improves the out-of-box AVS3 decode throughput of the distributed build without requiring end users to pass manual `-threads` overrides

- `tools/patches/mpv/0001-vo_libmpv-introduce-gpu-next-render-backend.patch`
  - vendors the current draft of [mpv-player/mpv#16818](https://github.com/mpv-player/mpv/pull/16818) into the local mpv patch stack
  - adds `MPV_RENDER_PARAM_BACKEND="gpu-next"` support to `vo_libmpv`, which is the missing upstream piece needed for IINA to experiment with `gpu-next` on the `libmpv` render API path
  - also carries local follow-up fixes in this repository, including `MPV_RENDER_PARAM_FLIP_Y` handling, `MPV_RENDER_PARAM_ICC_PROFILE` forwarding, mpv scaler / tone-mapping option mapping, and macOS `VideoToolbox` direct rendering / screenshot interop for the `libmpv` OpenGL path
  - reuses imported `VideoToolbox` GL textures across frames on macOS so the `gpu-next` direct-render path avoids per-frame texture churn and the associated CPU overhead

- `tools/patches/uavs3d/0001-arm64-neon-accelerate-10bit-output-conversion.patch`
  - adds an AArch64 NEON fast path for the 10-bit output conversion stage in `uavs3d`
  - reduces the cost of one of the hottest AVS3 decode-output formatting paths on Apple Silicon

- `tools/patches/uavs3d/0002-arm64-fix-and-enable-asm-10bit-output-conversion.patch`
  - fixes and enables the assembly-backed 10-bit output conversion path in `uavs3d`
  - keeps the accelerated conversion path bit-exact while restoring the intended arm64 implementation

- `tools/patches/uavs3d/0003-inter-pred-split-unidirectional-mc-fast-path.patch`
  - splits out a lighter unidirectional motion-compensation fast path in the inter-prediction pipeline
  - avoids paying the heavier shared-path overhead in common single-reference prediction cases

- `tools/patches/uavs3d/0004-inter-pred-hoist-uni-ref-ready-check.patch`
  - hoists a repeated unidirectional reference-readiness check out of the hottest inner path
  - trims branch and control overhead in inter prediction without changing decode output

- `tools/patches/uavs3d/0005-arm64-use-pair-store-for-hot-inter-pred-temp-writes.patch`
  - replaces hot temporary inter-prediction writes with more efficient pair stores on arm64
  - reduces temp-buffer store pressure in a frequently sampled motion-compensation path

- `tools/patches/uavs3d/0006-arm64-conv-fmt-16bit-use-faster-stores.patch`
  - uses faster arm64 store sequences in the 16-bit output format conversion path
  - improves a persistent decode-output hotspot while preserving bit-exact output

## Performance

Current Apple Silicon AVS2 10-bit benchmark status:

- latest local comparison run shows about `1.48x` decoder speedup
- current measured average decode time improved from about `~14.2s` to about `~9.6s` in the existing validation workflow
- the reported result is from a bit-exact-validated comparison, not from a relaxed or output-changing optimization mode

Current Apple Silicon AVS3 benchmark status:

- the distributed FFmpeg build now includes the Apple Silicon `libuavs3d` auto-thread tuning patch plus the accepted local `uavs3d` hot-path optimizations above
- in the local bit-exact validation workflow, a clean minimal FFmpeg + `uavs3d` baseline versus the full accepted AVS3 patch stack currently shows about `+16.12%` throughput at default auto threads
- the same clean-versus-patched comparison shows about `+9.82%` throughput at explicit `-threads 4`
- the reported AVS3 numbers are from bit-exact-validated comparisons and only include patches that were kept after direct end-to-end benchmarking

## Default environment variables

Defined in `tools/common.sh`:

- `WORK_ROOT=.work`
- `ARTIFACT_ROOT=artifacts`
- `FFMPEG_VERSION=8.0.1`
- `MPV_REF=v0.41.0`
- `LICENSE_FLAVOR=gpl`
- `TARGET_ARCH=arm64`
- `FFMPEG_PREFIX=$WORK_ROOT/ffmpeg-prefix`
- `MPV_PREFIX=$WORK_ROOT/mpv-prefix`
- `SOURCE_ROOT=.work/src`

Useful overrides:

- `LOCAL_PATCH_ROOT`
  - overrides the vendored patch root; default is `tools/patches`
- `AV3A_GIT_URL` / `AV3A_GIT_REF`
  - git source for AV3A; defaults to `https://github.com/nilaoda/Sourcecodeforplayer`
  - default ref: `e7d244d29454eb04c968cd98a30587303a9c15f8`
- `DAVS2_EXTRA_CFLAGS`
  - appends extra `davs2-10bit` compiler flags; on `arm64`, the default is tuned to remain friendly to Apple Silicon vectorization and the vendored NEON patch stack
- `DAVS2_EXTRA_LDFLAGS`
  - appends extra `davs2-10bit` linker flags
- `MPV_EXTRA_MESON_FLAGS`
  - appends extra Meson flags for mpv

## Artifacts

By default, artifacts are written to `artifacts`

Common outputs include:

- `ffmpeg-cli-bundle-macos-arm64-gpl-ffmpeg-8.0.1.zip`
  - CLI test bundle for direct AVS+ / AVS2 decoder and filter validation
- `iina-mpv-bundle-macos-arm64-gpl-ffmpeg-8.0.1-mpv-v0.41.0.zip`
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
- `davs2-10bit` builds successfully and can decode AVS2 10-bit content with the vendored AArch64 NEON optimization stack enabled by default
- the current Apple Silicon `davs2-10bit` patch stack has been validated against bit-exact decode checks while significantly improving AVS2 10-bit decode throughput in local benchmark runs
- the AVS+ patch stack preserves reliable progressive / interlaced scan tagging for downstream tools
- AVS2 sequence-display color metadata is now propagated through `davs2-10bit` and FFmpeg, so basic tags such as range, BT.2020 matrix / primaries, and HLG transfer characteristics are visible to downstream players and tools

# OpenCV 4.12.0

CrossDiff's photography analysis uses the upstream OpenCV `core` and `imgproc`
modules for `cvtColor(COLOR_RGB2HLS)`, `calcHist`, sample validation, and masking.
The C interface in `Sources/PhotoCVBridge` is CrossDiff integration code. OpenCV's
upstream algorithm source is not modified. Before compilation, CrossDiff replaces
the local project prefix with `<PROJECT>` in three CMake-generated metadata files
(`version_string.tmp`, `modules/core/version_string.inc`, and
`opencv_data_config.hpp`) so build information and data-directory hints do not
disclose the developer's local path. Compiler prefix maps also remove local paths
from diagnostic file names. No shipped binary is patched. No neural networks,
image codecs, IPP, or contributed modules are linked.

- Upstream: <https://github.com/opencv/opencv/tree/4.12.0>
- Source archive: <https://codeload.github.com/opencv/opencv/tar.gz/refs/tags/4.12.0>
- Archive SHA-256: `44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d`
- License: Apache License 2.0 (`LICENSE`), with original copyright attribution
  (`COPYRIGHT`) and retained component notices (`NOTICE-SOURCE.txt`,
  `SoftFloat-COPYING.txt`).

Run `bash scripts/prepare-opencv.sh` to reproduce the static libraries. Sources,
build tools, caches, and libraries remain under the project's `.build/photo-deps`.
An existing CMake is used when available; otherwise the script downloads
checksum-pinned Kitware CMake 3.31.6 into that directory. CMake is a build tool
and is not distributed with CrossDiff.

macOS provides Core Image and ImageIO for decoding, orientation, RAW rendering,
color management, and Lanczos resampling. These system frameworks are not
vendored. Library output describes the stated sRGB SDR analysis view; it does
not recover an editing recipe or establish sensor clipping.

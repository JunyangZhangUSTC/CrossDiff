#!/bin/bash
set -euo pipefail
image_check_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$image_check_root/scripts/project-env.sh"
source "$image_check_root/scripts/photo-build-flags.sh"
image_check_binary="$image_check_root/.build/native-checks/image-matching-bridge"
mkdir -p "$(dirname "$image_check_binary")"
xcrun clang++ -std=c++17 -arch "$photo_flags_arch" -mmacosx-version-min=14.0 -O2 \
  -ffile-prefix-map="$image_check_root"=. -fdebug-prefix-map="$image_check_root"=. \
  -I "$image_check_root/Sources/PhotoCVBridge/include" -I "$photo_flags_install/include/opencv4" \
  "$image_check_root/scripts/tests/ImageMatchingBridgeChecks.cpp" \
  -L "$photo_flags_bridge" -L "$photo_flags_install/lib" \
  -lPhotoCVBridge -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgproc -lopencv_core -lc++ -lz \
  -o "$image_check_binary"
"$image_check_binary"

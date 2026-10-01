#!/bin/bash
# Source after project-env.sh in scripts that compile the application using swiftc.
photo_flags_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$photo_flags_root/scripts/prepare-opencv.sh"
photo_flags_arch="${CROSSDIFF_ARCH:-$(uname -m)}"
photo_flags_install="$photo_flags_root/.build/photo-deps/install-$photo_flags_arch"
photo_flags_bridge="$photo_flags_root/.build/photo-deps/bridge-$photo_flags_arch"
mkdir -p "$photo_flags_bridge"
if [[ ! -f "$photo_flags_bridge/libPhotoCVBridge.a" ]] || \
   [[ "$photo_flags_root/Sources/PhotoCVBridge/PhotoCVBridge.cpp" -nt "$photo_flags_bridge/libPhotoCVBridge.a" ]] || \
   [[ "$photo_flags_root/Sources/PhotoCVBridge/include/PhotoCVBridge.h" -nt "$photo_flags_bridge/libPhotoCVBridge.a" ]]; then
  xcrun clang++ -std=c++17 -arch "$photo_flags_arch" -mmacosx-version-min=14.0 -O2 \
    -ffile-prefix-map="$photo_flags_root"=. -fdebug-prefix-map="$photo_flags_root"=. \
    -I "$photo_flags_root/Sources/PhotoCVBridge/include" -I "$photo_flags_install/include/opencv4" \
    -c "$photo_flags_root/Sources/PhotoCVBridge/PhotoCVBridge.cpp" -o "$photo_flags_bridge/PhotoCVBridge.o"
  xcrun ar rcs "$photo_flags_bridge/libPhotoCVBridge.a" "$photo_flags_bridge/PhotoCVBridge.o"
fi
crossdiff_photo_swift_flags=(-I "$photo_flags_root/Sources/PhotoCVBridge/include" \
  -L "$photo_flags_bridge" -L "$photo_flags_install/lib" -lPhotoCVBridge -lopencv_imgproc -lopencv_core -lc++ -lz)

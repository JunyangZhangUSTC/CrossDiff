#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p .build/cache .build/config .build/security
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product CrossDiff \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
binary_directory=$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --show-bin-path)
bundle="$PWD/dist/CrossDiff.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Replace the executable inode so a currently running preview keeps its mapped binary.
cp "$binary_directory/CrossDiff" "$bundle/Contents/MacOS/.CrossDiff.new"
# Distribute a stripped copy; keep the original build output for local debugging.
xcrun strip -S "$bundle/Contents/MacOS/.CrossDiff.new"
mv -f "$bundle/Contents/MacOS/.CrossDiff.new" "$bundle/Contents/MacOS/CrossDiff"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE NOTICE "$bundle/Contents/Resources/"
# Remove the development-only notice left in bundles produced by older builds.
rm -f "$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
swift scripts/make-icon.swift "$PWD/.build/CrossDiff.iconset"
swift scripts/pack-icon.swift "$PWD/.build/CrossDiff.iconset" "$bundle/Contents/Resources/CrossDiff.icns"
codesign --force --deep --sign - "$bundle"
printf 'Built: %s\n' "$bundle"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
edition=full
bundle="$PWD/dist/CrossDiff.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --edition) [[ $# -ge 2 ]] || { echo 'Missing --edition value.' >&2; exit 2; }; edition="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { echo 'Missing --output value.' >&2; exit 2; }; bundle="$2"; shift 2 ;;
    --help|-h) echo 'Usage: bash scripts/build-app.sh [--edition base|full] [--output <project-local path>/CrossDiff.app]'; exit 0 ;;
    *) echo 'Unexpected argument; use --help.' >&2; exit 2 ;;
  esac
done
[[ "$edition" == base || "$edition" == full ]] || { echo 'Edition must be base or full.' >&2; exit 2; }
# Resolve before writing, including existing symlink ancestors.
bundle="$(python3 - "$PWD" "$bundle" <<'CHECK_OUTPUT'
from pathlib import Path
import sys
root, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
if root not in output.parents or output.name != 'CrossDiff.app':
    sys.exit('The app output must be named CrossDiff.app and remain inside the project.')
if output.exists() and any(path.is_symlink() for path in output.rglob('*')):
    sys.exit('Refusing symlinked files inside the generated application bundle.')
print(output)
CHECK_OUTPUT
)"
bash scripts/prepare-opencv.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p .build/cache .build/config .build/security
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product CrossDiff \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product CrossDiffPluginHost \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product CrossDiffAudioMatcher
swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --product CrossDiffArchiveReader \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
binary_directory=$(swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -c release --show-bin-path)
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources/Plugins"
# Replace the executable inode so a currently running preview keeps its mapped binary.
cp "$binary_directory/CrossDiff" "$bundle/Contents/MacOS/.CrossDiff.new"
# Distribute a stripped copy; keep the original build output for local debugging.
xcrun strip -S "$bundle/Contents/MacOS/.CrossDiff.new"
mv -f "$bundle/Contents/MacOS/.CrossDiff.new" "$bundle/Contents/MacOS/CrossDiff"
cp "$binary_directory/CrossDiffPluginHost" "$bundle/Contents/Helpers/.CrossDiffPluginHost.new"
xcrun strip -S "$bundle/Contents/Helpers/.CrossDiffPluginHost.new"
codesign --force --sign - "$bundle/Contents/Helpers/.CrossDiffPluginHost.new"
mv -f "$bundle/Contents/Helpers/.CrossDiffPluginHost.new" "$bundle/Contents/Helpers/CrossDiffPluginHost"
cp "$binary_directory/CrossDiffAudioMatcher" "$bundle/Contents/Helpers/.CrossDiffAudioMatcher.new"
xcrun strip -S "$bundle/Contents/Helpers/.CrossDiffAudioMatcher.new"
codesign --force --sign - "$bundle/Contents/Helpers/.CrossDiffAudioMatcher.new"
mv -f "$bundle/Contents/Helpers/.CrossDiffAudioMatcher.new" "$bundle/Contents/Helpers/CrossDiffAudioMatcher"
cp "$binary_directory/CrossDiffArchiveReader" "$bundle/Contents/Helpers/.CrossDiffArchiveReader.new"
xcrun strip -S "$bundle/Contents/Helpers/.CrossDiffArchiveReader.new"
codesign --force --sign - "$bundle/Contents/Helpers/.CrossDiffArchiveReader.new"
mv -f "$bundle/Contents/Helpers/.CrossDiffArchiveReader.new" "$bundle/Contents/Helpers/CrossDiffArchiveReader"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE NOTICE "$bundle/Contents/Resources/"
mkdir -p "$bundle/Contents/Resources/ThirdParty/OpenCV"
cp ThirdParty/OpenCV/* "$bundle/Contents/Resources/ThirdParty/OpenCV/"
mkdir -p "$bundle/Contents/Resources/ThirdParty/AudioMatching"
cp ThirdParty/AudioMatching/* "$bundle/Contents/Resources/ThirdParty/AudioMatching/"
# Remove the development-only notice left in bundles produced by older builds.
rm -f "$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
swift scripts/make-icon.swift "$PWD/.build/CrossDiff.iconset"
swift scripts/pack-icon.swift "$PWD/.build/CrossDiff.iconset" "$bundle/Contents/Resources/CrossDiff.icns"
# The same generator writes release packages and the app's offline catalog.
python3 scripts/plugin_inventory.py --edition "$edition" --bundle-resources "$bundle/Contents/Resources"
codesign --force --sign - "$bundle"
printf 'Built (%s): %s\n' "$edition" "$bundle"

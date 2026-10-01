#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
render_build="$PWD/.build-readme"
mkdir -p "$render_build/data" "$render_build/module-cache" docs/assets/screenshots
render_sources="$(mktemp -d "$render_build/sources.XXXXXX")"
cp Sources/CrossDiff/*.swift "$render_sources/"
python3 - "$render_sources/CrossDiffApp.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source
path.write_text(source.replace('NativeUIRenderChecks.start()', 'ReadmeRenders.start()'))
PY
swiftc -swift-version 5 -module-cache-path "$render_build/module-cache" -emit-module -emit-library \
  -module-name CrossDiffCore Sources/CrossDiffCore/*.swift \
  -emit-module-path "$render_build/CrossDiffCore.swiftmodule" -o "$render_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$render_build/module-cache" \
  -I "$render_build" -L "$render_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$render_build" \
  "$render_sources"/*.swift scripts/tests/DeletionPreviewChecks.swift scripts/tests/ReadmeRenders.swift \
  -o "$render_build/readme-renders"
python3 scripts/package-pdf-plugin.py --output "$render_build/Plugins/PDF.crossdiffplugin"
python3 scripts/package-archive-plugin.py --output "$render_build/Plugins/Archive.crossdiffplugin"
CROSSDIFF_DATA_DIR="$render_build/data" CROSSDIFF_RENDER_DIR="$PWD/docs/assets/screenshots" CROSSDIFF_BUNDLED_PLUGINS_DIR="$render_build/Plugins" \
python3 - "$render_build/readme-renders" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=60)
except subprocess.TimeoutExpired:
    sys.exit('README render timed out; a native macOS application session is required.')
sys.exit(result.returncode)
PY

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--build-only" ) ]]; then
  echo 'Usage: bash scripts/render-readme.sh [--build-only]' >&2
  exit 2
fi
render_build="$PWD/.build-readme"
mkdir -p "$render_build/module-cache"
render_run="$(mktemp -d "$render_build/run.XXXXXX")"
render_sources="$render_run/sources"
mkdir -p "$render_sources/app" "$render_sources/core" "$render_run/data" \
  "$render_run/renders" "$render_run/tmp" "$render_run/runtime-home"
export TMPDIR="$render_run/tmp/"
export CFFIXED_USER_HOME="$render_run/runtime-home"
export CROSSDIFF_DATA_DIR="$render_run/data"
# Snapshot both modules and retain diagnostics under this isolated render run.
cp Sources/CrossDiff/*.swift "$render_sources/app/"
cp Sources/CrossDiffCore/*.swift "$render_sources/core/"
python3 - "$render_sources/app/CrossDiffApp.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source
path.write_text(source.replace('NativeUIRenderChecks.start()', 'ReadmeRenders.start()'))
PY
echo "Preparing README renderer; build log: $render_run/build.log"
(
source scripts/photo-build-flags.sh
swiftc -swift-version 5 -module-cache-path "$render_build/module-cache" -emit-module -emit-library \
  -module-name CrossDiffCore "$render_sources/core"/*.swift \
  -emit-module-path "$render_build/CrossDiffCore.swiftmodule" -o "$render_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$render_build/module-cache" \
  -I "$render_build" -L "$render_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$render_build" \
  "$render_sources/app"/*.swift scripts/tests/DeletionPreviewChecks.swift scripts/tests/ReadmeRenders.swift \
  -o "$render_build/readme-renders"
swiftc -swift-version 5 -module-cache-path "$render_build/module-cache" \
  Sources/CrossDiffPluginHost/main.swift -o "$render_build/CrossDiffPluginHost"
# Share the shipping Full inventory: Archive, PDF, Photography, API and Audio.
python3 scripts/plugin_inventory.py --edition full --bundle-resources "$render_run/Resources"
) >"$render_run/build.log" 2>&1
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built README renderer: $render_build/readme-renders"
  exit 0
fi
CROSSDIFF_RENDER_DIR="$render_run/renders" CROSSDIFF_BUNDLED_PLUGINS_DIR="$render_run/Resources/Plugins" \
CROSSDIFF_PLUGIN_HELPER="$render_build/CrossDiffPluginHost" \
python3 - "$render_build/readme-renders" "$render_run/renderer.log" <<'PY'
import subprocess, sys
try:
    with open(sys.argv[2], 'w') as log:
        result = subprocess.run([sys.argv[1]], stdout=log, stderr=subprocess.STDOUT, timeout=60)
except subprocess.TimeoutExpired:
    sys.exit('README render timed out; a native macOS application session is required. Log: ' + sys.argv[2])
if result.returncode:
    sys.exit('README render failed. Log: ' + sys.argv[2])
PY
# Export only the known PNG set after all captures succeed. Progress logs and
# test state stay in .build-readme, never alongside the published screenshots.
python3 - "$render_run/renders" "$PWD/docs/assets/screenshots" <<'PY'
from pathlib import Path
import shutil, sys
source, destination = map(Path, sys.argv[1:])
names = [f'{kind}-{locale}-{theme}.png'
         for kind in ('text', 'deletions', 'new')
         for locale in ('en', 'zh-CN') for theme in ('light', 'dark')]
for name in names:
    with (source / name).open('rb') as image:
        if image.read(8) != b'\x89PNG\r\n\x1a\n':
            sys.exit('Missing or invalid README screenshot: ' + name)
destination.mkdir(parents=True, exist_ok=True)
for name in names:
    shutil.copyfile(source / name, destination / name)
print(f'Exported {len(names)} native README screenshots to docs/assets/screenshots.')
PY

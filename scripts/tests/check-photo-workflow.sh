#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-photo-workflow"
mkdir -p "$check_build/module-cache" "$check_build/data" "$check_build/renders"
compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
mkdir -p "$compile_sources/app" "$compile_sources/core"
cp "$project_root/Sources/CrossDiff"/*.swift "$compile_sources/app/"
cp "$project_root/Sources/CrossDiffCore"/*.swift "$compile_sources/core/"
# Change only the disposable check copy; shipping lifecycle and windows are unchanged.
/usr/bin/python3 - "$compile_sources/app/CrossDiffApp.swift" "$compile_sources/app/MainWindowController.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source, 'Missing opt-in native check hook'
source = source.replace('NativeUIRenderChecks.start()', 'PhotoWorkflowChecks.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
window_path = pathlib.Path(sys.argv[2])
window_source = window_path.read_text()
constructor = 'NSWindow(contentRect:'
assert window_source.count(constructor) == 1, 'Expected one native main-window constructor'
window_path.write_text(window_source.replace(constructor, 'PhotoWorkflowCheckWindow(contentRect:', 1))
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$compile_sources/core"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources/app"/*.swift "$project_root/scripts/tests/DeletionPreviewChecks.swift" "$project_root/scripts/tests/PhotoWorkflowChecks.swift" -o "$check_build/photo-workflow-checks"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" "$project_root/Sources/CrossDiffPluginHost/main.swift" -o "$check_build/CrossDiffPluginHost"
python3 scripts/package-photography-plugin.py --output "$check_build/Plugins/Photography.crossdiffplugin"
python3 scripts/package-pdf-plugin.py --output "$check_build/Plugins/PDF.crossdiffplugin"
python3 scripts/package-plugin.py Plugins/Examples/JSON --output "$check_build/JSON.crossdiffplugin"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/photo-workflow-checks"
  exit 0
fi
CROSSDIFF_DATA_DIR="$check_build/data" CROSSDIFF_RENDER_DIR="$check_build/renders" CROSSDIFF_PLUGIN_HELPER="$check_build/CrossDiffPluginHost" CROSSDIFF_BUNDLED_PLUGINS_DIR="$check_build/Plugins" \
/usr/bin/python3 - "$check_build/photo-workflow-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=180)
except subprocess.TimeoutExpired:
    print('Native preview checks timed out; AppKit may require access to native application services.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

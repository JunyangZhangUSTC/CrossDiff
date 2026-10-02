#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-official-plugin-ui"
mkdir -p "$check_build/module-cache" "$check_build/data" "$check_build/renders"
compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
mkdir -p "$compile_sources/app" "$compile_sources/core"
cp "$project_root/Sources/CrossDiff"/*.swift "$compile_sources/app/"
cp "$project_root/Sources/CrossDiffCore"/*.swift "$compile_sources/core/"
# Change only the disposable check copy; the shipping app keeps its lifecycle.
/usr/bin/python3 - "$compile_sources/app/CrossDiffApp.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source, 'Missing opt-in native check hook'
source = source.replace('NativeUIRenderChecks.start()', 'OfficialPluginUIChecks.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$compile_sources/core"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources/app"/*.swift "$project_root/scripts/tests/DeletionPreviewChecks.swift" "$project_root/scripts/tests/OfficialPluginUIChecks.swift" -o "$check_build/official-plugin-ui-checks"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" "$project_root/Sources/CrossDiffPluginHost/main.swift" -o "$check_build/CrossDiffPluginHost"
python3 scripts/package-pdf-plugin.py --output "$check_build/PDF.crossdiffplugin"
python3 scripts/package-photography-plugin.py --output "$check_build/Photography.crossdiffplugin"
python3 scripts/package-api-plugin.py --output "$check_build/API.crossdiffplugin"
python3 scripts/package-archive-plugin.py --output "$check_build/Plugins/Archive.crossdiffplugin"
python3 - "$check_build" <<'PYCAT'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
entries = []
for name, path in [('Archive', root / 'Plugins/Archive.crossdiffplugin'), ('PDF', root / 'PDF.crossdiffplugin'), ('Photography', root / 'Photography.crossdiffplugin'), ('API', root / 'API.crossdiffplugin')]:
    data = path.read_bytes(); manifest = json.loads(data)['manifest']
    asset = f"CrossDiff-Plugin-{name}-{manifest['version']}.crossdiffplugin"
    entries.append({key:manifest[key] for key in ('id', 'version', 'name', 'summary')} | {
      'asset':asset, 'url':f'https://github.com/JunyangZhangUSTC/CrossDiff/releases/download/v0.8.0/{asset}',
      'sha256':hashlib.sha256(data).hexdigest(), 'size':len(data)})
(root / 'OfficialPlugins.json').write_text(json.dumps({'formatVersion':1,'releaseTag':'v0.8.0','plugins':entries}))
PYCAT
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/official-plugin-ui-checks"
  exit 0
fi
check_data="$(mktemp -d "$check_build/data.XXXXXX")"
CROSSDIFF_DATA_DIR="$check_data" CROSSDIFF_RENDER_DIR="$check_build/renders" CROSSDIFF_PLUGIN_HELPER="$check_build/CrossDiffPluginHost" CROSSDIFF_BUNDLED_PLUGINS_DIR="$check_build/Plugins" \
/usr/bin/python3 - "$check_build/official-plugin-ui-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=120)
except subprocess.TimeoutExpired:
    print('Native preview checks timed out; AppKit may require access to native application services.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

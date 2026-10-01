#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-deletion-preview-checks"
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
source = source.replace('NativeUIRenderChecks.start()', 'DeletionPreviewChecks.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$compile_sources/core"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources/app"/*.swift "$project_root/scripts/tests/DeletionPreviewChecks.swift" -o "$check_build/deletion-preview-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/deletion-preview-checks"
  exit 0
fi
CROSSDIFF_DATA_DIR="$check_build/data" CROSSDIFF_RENDER_DIR="$check_build/renders" \
/usr/bin/python3 - "$check_build/deletion-preview-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=45)
except subprocess.TimeoutExpired:
    print('Native preview checks timed out; AppKit may require access to native application services.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

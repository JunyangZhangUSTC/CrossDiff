#!/bin/bash
set -euo pipefail
integration_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$integration_root/scripts/project-env.sh"
cd "$integration_root"
integration_build="$integration_root/.build-integration-workflow"
mkdir -p "$integration_build/module-cache" "$integration_build/runs"
case "${1:-}" in ""|--build-only|--run-only) ;; *) echo 'Usage: check-integration-workflow.sh [--build-only|--run-only]' >&2; exit 2;; esac
if [[ "${1:-}" != --run-only ]]; then
  source "$integration_root/scripts/photo-build-flags.sh"
  integration_sources="$(mktemp -d "$integration_build/sources.XXXXXX")"
  mkdir -p "$integration_sources/app" "$integration_sources/core"
  cp Sources/CrossDiff/*.swift "$integration_sources/app/"
  cp Sources/CrossDiffCore/*.swift "$integration_sources/core/"
  python3 - "$integration_sources/app/CrossDiffApp.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source, 'Missing opt-in native check hook'
source = source.replace('NativeUIRenderChecks.start()', 'IntegrationWorkflowChecks.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
  swiftc -swift-version 5 -module-cache-path "$integration_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
    "$integration_sources/core"/*.swift -emit-module-path "$integration_build/CrossDiffCore.swiftmodule" -o "$integration_build/libCrossDiffCore.dylib"
  swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$integration_build/module-cache" \
    -I "$integration_build" -L "$integration_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$integration_build" \
    "$integration_sources/app"/*.swift scripts/tests/ImageMatchingFixtures.swift scripts/tests/VideoFixtures.swift \
    scripts/tests/IntegrationWorkflowChecks.swift -o "$integration_build/integration-workflow-checks"
  swiftc -swift-version 5 -module-cache-path "$integration_build/module-cache" Sources/CrossDiffPluginHost/main.swift \
    -o "$integration_build/CrossDiffPluginHost"
  python3 scripts/package-photography-plugin.py --output "$integration_build/Plugins/Photography.crossdiffplugin"
  python3 scripts/package-video-plugin.py --output "$integration_build/Plugins/Video.crossdiffplugin"
fi
if [[ "${1:-}" == --build-only ]]; then
  echo "Built: $integration_build/integration-workflow-checks"
  exit 0
fi
[[ -x "$integration_build/integration-workflow-checks" ]] || { echo 'Build the integration checks first.' >&2; exit 2; }
integration_run="$(mktemp -d "$integration_build/runs/run.XXXXXX")"
mkdir -p "$integration_run/data" "$integration_run/renders"
CROSSDIFF_DATA_DIR="$integration_run/data" CROSSDIFF_RENDER_DIR="$integration_run/renders" \
CROSSDIFF_PLUGIN_HELPER="$integration_build/CrossDiffPluginHost" CROSSDIFF_BUNDLED_PLUGINS_DIR="$integration_build/Plugins" \
python3 - "$integration_build/integration-workflow-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=240)
except subprocess.TimeoutExpired:
    print('Cross-module native checks timed out; no success is implied. Inspect this run’s project-local verdict and renders.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

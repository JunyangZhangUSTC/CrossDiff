#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
mode="${1:-}"
if [[ "$mode" != "" && "$mode" != "--build-only" && "$mode" != "--run-only" ]]; then
  echo "Usage: $0 [--build-only|--run-only]" >&2
  exit 2
fi
check_build="$project_root/.build-session-tab-checks"
mkdir -p "$check_build/module-cache" "$check_build/data" "$check_build/renders"
if [[ "$mode" != "--run-only" ]]; then
  compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
  trap 'rm -rf "$compile_sources"' EXIT
  mkdir -p "$compile_sources/app" "$compile_sources/core"
  cp "$project_root/Sources/CrossDiff"/*.swift "$compile_sources/app/"
  cp "$project_root/Sources/CrossDiffCore"/*.swift "$compile_sources/core/"
  cp "$project_root/scripts/tests/SessionTabChecks.swift" "$compile_sources/SessionTabChecks.swift"
  /usr/bin/python3 - "$compile_sources/app/CrossDiffApp.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source, 'Missing opt-in native check hook'
source = source.replace('NativeUIRenderChecks.start()', 'SessionTabChecks.start()')
# Baseline has no stable tab identifier. Add accessibility metadata only to the
# disposable test copy, leaving layout, selection and scrolling behavior intact.
if '"session-tab."' not in source:
    anchor = '.frame(maxWidth: 320).help(session.title)'
    assert source.count(anchor) == 1, 'Missing baseline tab metadata hook'
    source = source.replace(anchor, anchor + '\n        .accessibilityElement(children: .contain)\n        .accessibilityIdentifier("session-tab." + session.id.uuidString)')
path.write_text(source)
PY
  swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
    "$compile_sources/core"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
  swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
    -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
    "$compile_sources/app"/*.swift "$compile_sources/SessionTabChecks.swift" -o "$check_build/session-tab-checks"
fi
if [[ ! -x "$check_build/session-tab-checks" ]]; then
  echo "Missing test executable; run $0 --build-only first." >&2
  exit 2
fi
if [[ "$mode" == "--build-only" ]]; then
  echo "Built: $check_build/session-tab-checks"
  exit 0
fi
CROSSDIFF_DATA_DIR="$check_build/data" CROSSDIFF_RENDER_DIR="$check_build/renders" \
/usr/bin/python3 - "$check_build/session-tab-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=60)
except subprocess.TimeoutExpired:
    print('Session tab checks timed out; AppKit may require native application services.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

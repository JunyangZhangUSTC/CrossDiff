#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-ui-checks"
variant="${1:-current}"
build_only="${2:-}"
input_style="${CROSSDIFF_INPUT_STYLE:-plain}"
case "$input_style" in
  plain) fixture_suffix="" ;;
  white-attributed|prefilled|ime-commit) fixture_suffix="-$input_style" ;;
  *) echo 'Unsupported CROSSDIFF_INPUT_STYLE' >&2; exit 2 ;;
esac
if [[ "$variant" != "current" && "$variant" != "baseline" && "$variant" != "diagnosis-011" ]]; then
  echo 'Usage: render-native-ui.sh [current|baseline|diagnosis-011] [--build-only]' >&2
  exit 2
fi
mkdir -p "$check_build/module-cache" "$check_build/$variant$fixture_suffix-data" "$check_build/renders/$variant$fixture_suffix"
if [[ "$variant" == "baseline" ]]; then
  app_sources="$check_build/baseline-sources"
  core_sources="$check_build/baseline-core"
elif [[ "$variant" == "diagnosis-011" ]]; then
  app_sources="$check_build/diagnosis-011-sources"
  core_sources="$check_build/diagnosis-011-core"
else
  app_sources="$project_root/Sources/CrossDiff"
  core_sources="$project_root/Sources/CrossDiffCore"
fi
# Freeze the files used by this invocation before compiling. Other work may
# continue in the shared checkout without mixing source revisions in a render.
compile_sources="$(mktemp -d "$check_build/$variant-compile.XXXXXX")"
cp "$app_sources"/*.swift "$compile_sources/"
# Older snapshots predate the opt-in hook. Inject it into the disposable copy.
/usr/bin/python3 - "$compile_sources/CrossDiffApp.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
if 'NativeUIRenderChecks.start()' not in source:
    source = source.replace('final class AppDelegate: NSObject, NSApplicationDelegate {', '''final class AppDelegate: NSObject, NSApplicationDelegate {
    #if CROSSDIFF_UI_CHECKS
    func applicationDidFinishLaunching(_ notification: Notification) { NativeUIRenderChecks.start() }
    #endif''')
source = source.replace('.onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }', '''.onAppear {
                    #if !CROSSDIFF_UI_CHECKS
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    #endif
                }''')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }', 'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$core_sources"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
set --
if [[ -f "$compile_sources/ComparisonTheme.swift" ]]; then
  set -- -D CROSSDIFF_EXPLICIT_THEME
fi
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS "$@" -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources"/*.swift "$project_root/scripts/tests/NativeUIRenderChecks.swift" -o "$check_build/$variant-ui-checks"
if [[ "$build_only" == "--build-only" ]]; then
  echo "Built diagnostic renderer: $check_build/$variant-ui-checks"
  exit 0
fi
CROSSDIFF_DATA_DIR="$check_build/$variant$fixture_suffix-data" CROSSDIFF_RENDER_DIR="$check_build/renders/$variant$fixture_suffix" \
/usr/bin/python3 - "$check_build/$variant-ui-checks" <<'PYRUN'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=30)
except subprocess.TimeoutExpired:
    print("Native renderer timed out; a restricted sandbox may block AppKit launch services.", file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PYRUN

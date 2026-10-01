#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-audio-workflow"
mkdir -p "$check_build/module-cache" "$check_build/data" "$check_build/renders" "$check_build/fixtures"
compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
mkdir -p "$compile_sources/app" "$compile_sources/core"
cp "$project_root/Sources/CrossDiff"/*.swift "$compile_sources/app/"
cp "$project_root/Sources/CrossDiffCore"/*.swift "$compile_sources/core/"
/usr/bin/python3 - "$compile_sources/app/CrossDiffApp.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source, 'Missing opt-in native check hook'
source = source.replace('NativeUIRenderChecks.start()', 'AudioWorkflowChecks.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$compile_sources/core"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources/app"/*.swift "$project_root/scripts/tests/DeletionPreviewChecks.swift" "$project_root/scripts/tests/AudioWorkflowChecks.swift" -o "$check_build/audio-workflow-checks"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" "$project_root/Sources/CrossDiffPluginHost/main.swift" -o "$check_build/CrossDiffPluginHost"
python3 scripts/package-audio-plugin.py --output "$check_build/Plugins/Audio.crossdiffplugin"
bash scripts/audio-research/build-matcher.sh
PYTHONDONTWRITEBYTECODE=1 python3 - "$check_build/fixtures" <<'PY'
import array, importlib.util, pathlib, sys, wave
path = pathlib.Path('scripts/audio-research/check-matcher.py')
spec = importlib.util.spec_from_file_location('audio_check_fixture', path)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
source = fixture.signal(918)
rate = fixture.RATE
right = source[27*rate:39*rate] + source[4*rate:16*rate]
for name, values in [('source.wav', source), ('reordered.wav', right)]:
    samples = array.array('h', (round(max(-1, min(1, value)) * 32767) for value in values))
    if sys.byteorder != 'little': samples.byteswap()
    with wave.open(str(pathlib.Path(sys.argv[1]) / name), 'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(rate); output.writeframes(samples.tobytes())
PY
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/audio-workflow-checks"
  exit 0
fi
data_dir="$(mktemp -d "$check_build/data/run.XXXXXX")"
CROSSDIFF_DATA_DIR="$data_dir" CROSSDIFF_RENDER_DIR="$check_build/renders" CROSSDIFF_PLUGIN_HELPER="$check_build/CrossDiffPluginHost" \
CROSSDIFF_AUDIO_HELPER="$project_root/.build/audio-research/bin/CrossDiffAudioMatcher" CROSSDIFF_BUNDLED_PLUGINS_DIR="$check_build/Plugins" \
/usr/bin/python3 - "$check_build/audio-workflow-checks" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=240)
except subprocess.TimeoutExpired:
    print('Audio workflow checks timed out; AppKit or the local matching helper may require native service access.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

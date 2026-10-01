#!/bin/bash
set -euo pipefail
audio_render_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$audio_render_root/scripts/project-env.sh"
cd "$audio_render_root"
source scripts/photo-build-flags.sh
audio_render_build="$audio_render_root/.build-audio-readme"
mkdir -p "$audio_render_build/module-cache" "$audio_render_build/data" "$audio_render_build/renders" "$audio_render_build/fixtures"
audio_render_sources="$(mktemp -d "$audio_render_build/sources.XXXXXX")"
mkdir -p "$audio_render_sources/app" "$audio_render_sources/core"
cp Sources/CrossDiff/*.swift "$audio_render_sources/app/"
cp Sources/CrossDiffCore/*.swift "$audio_render_sources/core/"
python3 - "$audio_render_sources/app/CrossDiffApp.swift" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'NativeUIRenderChecks.start()' in source
source = source.replace('NativeUIRenderChecks.start()', 'AudioReadmeCapture.start()')
source = source.replace('func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }',
                        'func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }')
path.write_text(source)
PY
swiftc -swift-version 5 -module-cache-path "$audio_render_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$audio_render_sources/core"/*.swift -emit-module-path "$audio_render_build/CrossDiffCore.swiftmodule" -o "$audio_render_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$audio_render_build/module-cache" \
  -I "$audio_render_build" -L "$audio_render_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$audio_render_build" \
  "$audio_render_sources/app"/*.swift scripts/tests/DeletionPreviewChecks.swift scripts/tests/AudioWorkflowChecks.swift \
  scripts/tests/AudioReadmeCapture.swift -o "$audio_render_build/audio-readme-capture"
swiftc -swift-version 5 -module-cache-path "$audio_render_build/module-cache" Sources/CrossDiffPluginHost/main.swift -o "$audio_render_build/CrossDiffPluginHost"
python3 scripts/package-audio-plugin.py --output "$audio_render_build/Plugins/Audio.crossdiffplugin"
bash scripts/audio-research/build-matcher.sh
python3 - "$audio_render_build/fixtures" <<'PY'
import array, importlib.util, math, pathlib, sys, wave
spec = importlib.util.spec_from_file_location('audio_readme_fixture', 'scripts/audio-research/check-matcher.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.RATE = rate = 48000
source = fixture.signal(918, seconds=30)
sections = [(1, 10, 1.5), (12, 22, 1.15), (25, 29, 0.9)]
for i in range(len(source)):
    t = i / rate
    gain = 0
    for index, (start, end, amplitude) in enumerate(sections):
        if start <= t < end:
            u = t - start
            cycle = 0.78 + index * 0.15
            phase = (u % cycle) / cycle
            pulse = math.sin(math.pi * phase / 0.8) ** 2 if phase < 0.8 else 0
            arch = math.sin(math.pi * u / (end - start)) ** 0.35
            gain = amplitude * arch * (0.08 + 0.92 * pulse)
            break
    source[i] *= gain
edited = source[12*rate:22*rate] + array.array('f', [0]) * int(0.8*rate) + source[rate:10*rate]
for names, values in [(('原始录音.wav', 'Studio session.wav'), source), (('剪辑版本.wav', 'Final edit.wav'), edited)]:
    samples = array.array('h', (round(max(-1, min(1, value)) * 32767) for value in values))
    if sys.byteorder != 'little': samples.byteswap()
    for name in names:
        with wave.open(str(pathlib.Path(sys.argv[1]) / name), 'wb') as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(rate); output.writeframes(samples.tobytes())
PY
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $audio_render_build/audio-readme-capture"
  exit 0
fi
audio_render_data="$(mktemp -d "$audio_render_build/data/run.XXXXXX")"
CROSSDIFF_DATA_DIR="$audio_render_data" CROSSDIFF_RENDER_DIR="$audio_render_build/renders" CROSSDIFF_PLUGIN_HELPER="$audio_render_build/CrossDiffPluginHost" \
CROSSDIFF_AUDIO_HELPER="$audio_render_root/.build/audio-research/bin/CrossDiffAudioMatcher" CROSSDIFF_BUNDLED_PLUGINS_DIR="$audio_render_build/Plugins" \
python3 - "$audio_render_build/audio-readme-capture" <<'PY'
import subprocess, sys
try:
    result = subprocess.run([sys.argv[1]], timeout=180)
except subprocess.TimeoutExpired:
    sys.exit('Audio README capture timed out; native macOS service access may be required.')
sys.exit(result.returncode)
PY
mkdir -p docs/assets/screenshots
for audio_render_locale in zh-CN en; do
  for audio_render_theme in light dark; do
    cp "$audio_render_build/renders/audio-$audio_render_locale-$audio_render_theme.png" docs/assets/screenshots/
  done
done
echo "Wrote four real audio screenshots to docs/assets/screenshots. README table supplies the border."

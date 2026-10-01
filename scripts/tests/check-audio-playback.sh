#!/bin/bash
set -euo pipefail
audio_playback_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$audio_playback_root/scripts/project-env.sh"
cd "$audio_playback_root"
audio_playback_build="$audio_playback_root/.build-audio-playback-checks"
mkdir -p "$audio_playback_build/fixtures" "$audio_playback_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$audio_playback_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$audio_playback_build/CrossDiffCore.swiftmodule" -o "$audio_playback_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$audio_playback_build/module-cache" \
  -I "$audio_playback_build" -L "$audio_playback_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$audio_playback_build" \
  Sources/CrossDiff/AudioAnalysisEngine.swift Sources/CrossDiff/AudioPlaybackController.swift \
  scripts/tests/AudioPlaybackChecks.swift -o "$audio_playback_build/audio-playback-checks"
if [[ "${1:-}" == "--build-only" ]]; then echo "Built silent offline audio playback checks."; exit 0; fi
"$audio_playback_build/audio-playback-checks" "$audio_playback_build/fixtures"

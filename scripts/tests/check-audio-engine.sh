#!/bin/bash
set -euo pipefail
audio_check_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$audio_check_root/scripts/project-env.sh"
cd "$audio_check_root"
audio_check_build="$audio_check_root/.build-audio-engine-checks"
mkdir -p "$audio_check_build/fixtures" "$audio_check_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$audio_check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$audio_check_build/CrossDiffCore.swiftmodule" -o "$audio_check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$audio_check_build/module-cache" \
  -I "$audio_check_build" -L "$audio_check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$audio_check_build" \
  Sources/CrossDiff/AudioAnalysisEngine.swift scripts/tests/AudioEngineChecks.swift -o "$audio_check_build/audio-engine-checks"
if [[ "${1:-}" == "--build-only" ]]; then echo "Built audio engine checks."; exit 0; fi
"$audio_check_build/audio-engine-checks" "$audio_check_build/fixtures"

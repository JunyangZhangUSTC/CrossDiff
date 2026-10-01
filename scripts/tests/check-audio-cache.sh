#!/bin/bash
set -euo pipefail
audio_cache_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$audio_cache_root/scripts/project-env.sh"
cd "$audio_cache_root"
audio_cache_build="$audio_cache_root/.build-audio-cache-checks"
mkdir -p "$audio_cache_build/fixtures" "$audio_cache_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$audio_cache_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$audio_cache_build/CrossDiffCore.swiftmodule" -o "$audio_cache_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$audio_cache_build/module-cache" \
  -I "$audio_cache_build" -L "$audio_cache_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$audio_cache_build" \
  Sources/CrossDiff/AudioCacheStore.swift scripts/tests/AudioCacheChecks.swift -o "$audio_cache_build/audio-cache-checks"
if [[ "${1:-}" == "--build-only" ]]; then echo "Built audio cache checks."; exit 0; fi
python3 - "$audio_cache_build/audio-cache-checks" "$audio_cache_build/fixtures" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], timeout=45)
except subprocess.TimeoutExpired:
    print('Audio cache checks timed out.', file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

#!/bin/bash
set -euo pipefail
photo_check_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$photo_check_root/scripts/project-env.sh"
source "$photo_check_root/scripts/photo-build-flags.sh"
cd "$photo_check_root"
photo_check_build="$photo_check_root/.build-photo-checks"
mkdir -p "$photo_check_build/fixtures" "$photo_check_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$photo_check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$photo_check_build/CrossDiffCore.swiftmodule" -o "$photo_check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$photo_check_build/module-cache" \
  -I "$photo_check_build" -L "$photo_check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$photo_check_build" \
  "${crossdiff_photo_swift_flags[@]}" Sources/CrossDiff/PhotoAnalysisEngine.swift Sources/CrossDiff/PhotoMetadataReader.swift \
  scripts/tests/PhotoEngineChecks.swift -o "$photo_check_build/photo-engine-checks"
if [[ "${1:-}" == "--build-only" ]]; then echo "Built photography engine checks."; exit 0; fi
"$photo_check_build/photo-engine-checks" "$photo_check_build/fixtures"

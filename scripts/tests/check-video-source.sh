#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-video-source-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
architecture="$(uname -m)"
swiftc -swift-version 5 -target "$architecture-apple-macosx14.0" -module-cache-path "$check_build/module-cache" \
  -emit-module -emit-library -module-name CrossDiffCore Sources/CrossDiffCore/Localization.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -target "$architecture-apple-macosx14.0" -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/VideoSourceService.swift Sources/CrossDiff/VideoPlaybackCoordinator.swift \
  scripts/tests/VideoFixtures.swift scripts/tests/VideoSourceChecks.swift -o "$check_build/video-source-checks"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
"$check_build/video-source-checks" "$check_build/fixtures"

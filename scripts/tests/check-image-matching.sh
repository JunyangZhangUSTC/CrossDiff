#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-image-matching-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/Localization.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/ImageComparisonRenderer.swift Sources/CrossDiff/ImageTransformGeometry.swift \
  Sources/CrossDiff/ImageComparisonModel.swift Sources/CrossDiff/ImageMatchingEngine.swift \
  scripts/tests/ImageMatchingFixtures.swift scripts/tests/ImageMatchingChecks.swift -o "$check_build/image-matching-checks"
"$check_build/image-matching-checks" "$check_build/fixtures"

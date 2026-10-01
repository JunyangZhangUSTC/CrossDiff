#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-binary-core-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
swiftc -O -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/BinaryFileSource.swift \
  Sources/CrossDiffCore/BinaryComparison.swift Sources/CrossDiffCore/BinaryRowLayout.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/BinaryCoreChecks.swift -o "$check_build/binary-core-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/binary-core-checks"
  exit 0
fi
"$check_build/binary-core-checks" "$check_build/fixtures"

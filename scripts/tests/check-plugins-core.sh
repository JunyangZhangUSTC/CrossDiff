#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-plugin-core-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/PluginProtocol.swift" \
  "$project_root/Sources/CrossDiffCore/AudioComparison.swift" \
  "$project_root/Sources/CrossDiffCore/OfficeComparison.swift" \
  "$project_root/Sources/CrossDiffCore/APIComparisonResult.swift" \
  "$project_root/Sources/CrossDiffCore/PluginPackage.swift" \
  "$project_root/Sources/CrossDiffCore/PluginStore.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/scripts/tests/PluginCoreChecks.swift" -o "$check_build/plugin-core-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/plugin-core-checks"
  exit 0
fi
"$check_build/plugin-core-checks" "$check_build/fixtures"

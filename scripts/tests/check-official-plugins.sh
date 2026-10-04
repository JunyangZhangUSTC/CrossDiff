#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-official-plugins"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/PluginProtocol.swift" \
  "$project_root/Sources/CrossDiffCore/AudioComparison.swift" \
  "$project_root/Sources/CrossDiffCore/VideoComparison.swift" \
  "$project_root/Sources/CrossDiffCore/OfficeComparison.swift" \
  "$project_root/Sources/CrossDiffCore/APIComparisonResult.swift" \
  "$project_root/Sources/CrossDiffCore/PluginPackage.swift" \
  "$project_root/Sources/CrossDiffCore/PluginStore.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginRunner.swift" \
  "$project_root/Sources/CrossDiff/PluginDownload.swift" \
  "$project_root/Sources/CrossDiff/OfficialPluginCatalog.swift" \
  "$project_root/Sources/CrossDiff/PluginManager.swift" \
  "$project_root/scripts/tests/OfficialPluginChecks.swift" -o "$check_build/official-plugin-checks"
"$check_build/official-plugin-checks" "$check_build/fixtures"

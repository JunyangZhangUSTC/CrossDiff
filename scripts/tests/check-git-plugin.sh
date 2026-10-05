#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-git-plugin"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
python3 "$project_root/scripts/package-git-plugin.py" --output "$check_build/fixtures/Git.crossdiffplugin"
python3 "$project_root/scripts/package-git-plugin.py" --output "$check_build/fixtures/Git-again.crossdiffplugin"
cmp "$check_build/fixtures/Git.crossdiffplugin" "$check_build/fixtures/Git-again.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  "$project_root/Sources/CrossDiffPluginHost/main.swift" -o "$check_build/CrossDiffPluginHost"
swiftc -O -enable-testing -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/PluginProtocol.swift" \
  "$project_root/Sources/CrossDiffCore"/Git*.swift \
  "$project_root/Sources/CrossDiffCore/AudioComparison.swift" \
  "$project_root/Sources/CrossDiffCore/VideoComparison.swift" \
  "$project_root/Sources/CrossDiffCore/OfficeComparison.swift" \
  "$project_root/Sources/CrossDiffCore/APIComparisonResult.swift" \
  "$project_root/Sources/CrossDiffCore/PluginPackage.swift" \
  "$project_root/Sources/CrossDiffCore/PluginStore.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginRunner.swift" \
  "$project_root/scripts/tests/GitPluginChecks.swift" -o "$check_build/git-plugin-checks"
"$check_build/git-plugin-checks" "$project_root" "$check_build"

swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginRunner.swift" \
  "$project_root/Sources/CrossDiff/PluginDownload.swift" \
  "$project_root/Sources/CrossDiff/OfficialPluginCatalog.swift" \
  "$project_root/Sources/CrossDiff/PluginManager.swift" \
  "$project_root/Sources/CrossDiff/GitPluginComparison.swift" \
  "$project_root/scripts/tests/GitPluginBatchChecks.swift" -o "$check_build/git-plugin-batch-checks"
"$check_build/git-plugin-batch-checks" "$check_build"

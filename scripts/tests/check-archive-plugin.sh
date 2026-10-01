#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-archive-plugin"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
python3 "$project_root/scripts/package-archive-plugin.py" --output "$check_build/fixtures/Archive.crossdiffplugin"
python3 "$project_root/scripts/package-archive-plugin.py" --output "$check_build/fixtures/Archive-again.crossdiffplugin"
cmp "$check_build/fixtures/Archive.crossdiffplugin" "$check_build/fixtures/Archive-again.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  "$project_root/Sources/CrossDiffPluginHost/main.swift" -o "$check_build/CrossDiffPluginHost"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/PluginProtocol.swift" \
  "$project_root/Sources/CrossDiffCore/APIComparisonResult.swift" \
  "$project_root/Sources/CrossDiffCore/PluginPackage.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginRunner.swift" \
  "$project_root/scripts/tests/ArchivePluginChecks.swift" -o "$check_build/archive-plugin-checks"
"$check_build/archive-plugin-checks" "$project_root" "$check_build"

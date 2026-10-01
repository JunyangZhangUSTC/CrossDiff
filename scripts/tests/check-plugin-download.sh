#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-plugin-download"
mkdir -p "$check_build/module-cache"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginDownload.swift" \
  "$project_root/scripts/tests/PluginDownloadChecks.swift" -o "$check_build/plugin-download-checks"
"$check_build/plugin-download-checks"

#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-plugin-runtime"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  "$project_root/Sources/CrossDiffPluginHost/main.swift" \
  -o "$check_build/CrossDiffPluginHost"
python3 "$project_root/scripts/tests/PluginHostChecks.py" "$check_build/CrossDiffPluginHost"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/PluginProtocol.swift" \
  "$project_root/Sources/CrossDiffCore/APIComparisonResult.swift" \
  "$project_root/Sources/CrossDiffCore/PluginPackage.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/PluginRunner.swift" \
  "$project_root/scripts/tests/PluginRuntimeChecks.swift" -o "$check_build/plugin-runtime-checks"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  "$project_root/scripts/tests/NativePluginRuntimeFixture.swift" -o "$check_build/fixtures/native-plugin"
codesign --force --sign - "$check_build/fixtures/native-plugin"
"$check_build/plugin-runtime-checks" "$check_build/CrossDiffPluginHost" "$check_build/fixtures/native-plugin"

#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-api-plugin-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
python3 scripts/package-api-plugin.py --output "$check_build/API.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" Sources/CrossDiffPluginHost/main.swift -o "$check_build/CrossDiffPluginHost"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/PluginRunner.swift scripts/tests/APIPluginChecks.swift -o "$check_build/api-plugin-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built api plugin checks."
  exit 0
fi
"$check_build/api-plugin-checks" "$project_root"

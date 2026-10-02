#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-office-plugin-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
cp Sources/CrossDiffCore/*.swift "$compile_sources/"
python3 scripts/package-office-plugin.py --output "$check_build/Office.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" Sources/CrossDiffPluginHost/main.swift -o "$check_build/CrossDiffPluginHost"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$compile_sources"/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/PluginRunner.swift scripts/tests/OfficePluginChecks.swift -o "$check_build/office-plugin-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built Office plugin checks."
  exit 0
fi
"$check_build/office-plugin-checks" "$project_root"

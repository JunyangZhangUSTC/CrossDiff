#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-photography-plugin-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
python3 scripts/package-photography-plugin.py --output "$check_build/Photography.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/PhotographyPluginChecks.swift -o "$check_build/photography-plugin-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built photography plugin checks."
  exit 0
fi
"$check_build/photography-plugin-checks" "$project_root"

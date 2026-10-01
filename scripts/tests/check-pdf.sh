#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-pdf-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
python3 scripts/package-pdf-plugin.py --output "$check_build/PDF.crossdiffplugin"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  scripts/tests/PDFAlgorithmChecks.swift -o "$check_build/pdf-algorithm-checks"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/PDFComparisonDocument.swift Sources/CrossDiff/PDFComparisonModel.swift \
  scripts/tests/PDFComparisonChecks.swift -o "$check_build/pdf-comparison-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built PDF comparison and algorithm checks."
  exit 0
fi
"$check_build/pdf-algorithm-checks" Plugins/PDF/compare.js
"$check_build/pdf-comparison-checks" "$project_root"

#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-office-import-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
python3 scripts/tests/make-office-fixtures.py "$check_build/fixtures"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/OfficeImportChecks.swift -o "$check_build/office-import-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built Office import checks."
  exit 0
fi
"$check_build/office-import-checks" "$check_build/fixtures"

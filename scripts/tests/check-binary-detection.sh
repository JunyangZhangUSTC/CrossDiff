#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-binary-detection"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
export CLANG_MODULE_CACHE_PATH="$check_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root/Sources/CrossDiffCore/Localization.swift" \
  "$project_root/Sources/CrossDiffCore/BinaryFileDetection.swift" \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/scripts/tests/BinaryDetectionChecks.swift" -o "$check_build/binary-detection-checks"
python3 - "$check_build/binary-detection-checks" "$check_build/fixtures" <<'PYTHON'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=20)
PYTHON

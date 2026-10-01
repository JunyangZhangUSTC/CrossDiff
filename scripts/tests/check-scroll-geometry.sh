#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-scroll-checks"
mkdir -p "$check_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" \
  "$project_root/Sources/CrossDiff/ComparisonScrollView.swift" \
  "$project_root/scripts/tests/ScrollGeometryChecks.swift" \
  -o "$check_build/scroll-geometry-checks"
/usr/bin/python3 - "$check_build/scroll-geometry-checks" "${1:-fixed}" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], timeout=25)
except subprocess.TimeoutExpired:
    print("Scroll geometry checks timed out; AppKit may require permission outside the sandbox.", file=sys.stderr)
    sys.exit(3)
sys.exit(result.returncode)
PY

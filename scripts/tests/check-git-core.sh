#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-git-core-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
swiftc -O -enable-testing -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/GitModels.swift \
  Sources/CrossDiffCore/GitProcess.swift Sources/CrossDiffCore/GitRemote.swift Sources/CrossDiffCore/GitRepository.swift Sources/CrossDiffCore/GitLocalSnapshot.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/GitCoreChecks.swift -o "$check_build/git-core-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/git-core-checks"
  exit 0
fi
"$check_build/git-core-checks" "$check_build/fixtures"

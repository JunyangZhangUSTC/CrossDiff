#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-archive-native-checks"
mkdir -p "$check_build/module-cache"
python3 scripts/tests/fixtures/archive-native/generate.py "$check_build/fixtures"
swiftc -O -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/Archive*.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -O -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiffArchiveReader/main.swift -o "$check_build/CrossDiffArchiveReader"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/ArchiveNativeChecks.swift -o "$check_build/archive-native-checks"
clang -O2 -Wall -Wextra -Werror scripts/tests/fixtures/archive-native/HelperFixture.c -o "$check_build/helper-fixture"
for kind in fail crash invalid oversized cancel; do
  ln -sf helper-fixture "$check_build/fake-$kind"
done
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/archive-native-checks"
  exit 0
fi
"$check_build/archive-native-checks" "$check_build/fixtures" "$check_build/CrossDiffArchiveReader"

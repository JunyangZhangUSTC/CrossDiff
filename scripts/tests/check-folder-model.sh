#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
check_build="$PWD/.build/folder-model-checks"
mkdir -p "$check_build"
swiftc -O -swift-version 5 -module-cache-path .build/module-cache -emit-module -emit-library -module-name CrossDiffCore \
    Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/FolderComparison.swift Sources/CrossDiffCore/FolderBrowser.swift \
    -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -O -swift-version 5 -module-cache-path .build/module-cache -I "$check_build" -L "$check_build" -lCrossDiffCore \
    -Xlinker -rpath -Xlinker "$check_build" \
    Sources/CrossDiff/FolderComparisonModel.swift scripts/tests/FolderModelChecks.swift -o "$check_build/folder-model-checks"
"$check_build/folder-model-checks"

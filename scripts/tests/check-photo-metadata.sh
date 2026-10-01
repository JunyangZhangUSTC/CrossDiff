#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
check_build="$PWD/.build-photo-metadata"
mkdir -p "$check_build"
swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/PhotoMetadataReader.swift scripts/tests/PhotoMetadataChecks.swift -o "$check_build/check"
"$check_build/check" "$check_build/fixtures"

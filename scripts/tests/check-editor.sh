#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-editor-checks"
mkdir -p "$check_build/module-cache"
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root"/Sources/CrossDiffCore/*.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$project_root/Sources/CrossDiff/ComparisonTheme.swift" \
  "$project_root/Sources/CrossDiff/TextNavigationIndicator.swift" \
  "$project_root/Sources/CrossDiff/AppSettings.swift" \
  "$project_root/Sources/CrossDiff/ComparisonScrollView.swift" \
  "$project_root/Sources/CrossDiff/Workspace.swift" \
  "$project_root/Sources/CrossDiff/NativeTextEditor.swift" \
  "$project_root/Sources/CrossDiff/TextAlignment.swift" \
  "$project_root/scripts/tests/EditorAppearanceChecks.swift" \
  "$project_root/scripts/tests/EditorStateChecks.swift" -o "$check_build/editor-checks"
"$check_build/editor-checks"

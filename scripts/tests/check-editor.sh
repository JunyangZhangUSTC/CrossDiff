#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
source "$project_root/scripts/photo-build-flags.sh"
check_build="$project_root/.build-editor-checks"
mkdir -p "$check_build/module-cache" "$check_build/data"
compile_sources="$(mktemp -d "$check_build/sources.XXXXXX")"
cp "$project_root/Sources/CrossDiff"/*.swift "$compile_sources/"
# Compile the complete current app graph while this check owns its entry point.
/usr/bin/python3 - "$compile_sources/CrossDiffApp.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert '@main\nstruct CrossDiffApp' in text
assert 'NativeUIRenderChecks.start()' in text
path.write_text(text.replace('@main\nstruct CrossDiffApp', 'struct CrossDiffApp')
               .replace('NativeUIRenderChecks.start()', '// Check owns application startup.'))
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  "$project_root"/Sources/CrossDiffCore/*.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc "${crossdiff_photo_swift_flags[@]}" -swift-version 5 -D CROSSDIFF_UI_CHECKS -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  "$compile_sources"/*.swift \
  "$project_root/scripts/tests/EditorAppearanceChecks.swift" \
  "$project_root/scripts/tests/EditorStateChecks.swift" -o "$check_build/editor-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/editor-checks"
  exit 0
fi
CROSSDIFF_DATA_DIR="$check_build/data" "$check_build/editor-checks"

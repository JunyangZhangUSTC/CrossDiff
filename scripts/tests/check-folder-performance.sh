#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
mkdir -p .build/folder-performance

# Optional: compare exactly the same fixtures with a saved pre-change implementation.
# The baseline source is an explicit local input; this script does not alter Git state.
if [[ "${1:-}" == "--baseline-source" && -n "${2:-}" && $# -eq 2 ]]; then
    swiftc -O -swift-version 5 -module-cache-path .build/module-cache -D FOLDER_BASELINE \
        Sources/CrossDiffCore/Localization.swift "$2" scripts/tests/FolderPerformanceChecks.swift \
        -o .build/folder-performance/baseline-comparison
    .build/folder-performance/baseline-comparison | tee .build/folder-performance/baseline-comparison.txt
elif [[ $# -ne 0 ]]; then
    printf 'Usage: bash scripts/tests/check-folder-performance.sh [--baseline-source saved/FolderComparison.swift]\n' >&2
    exit 2
fi

swiftc -O -swift-version 5 -module-cache-path .build/module-cache \
    Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/FolderComparison.swift \
    scripts/tests/FolderPerformanceChecks.swift -o .build/folder-performance/current-comparison
.build/folder-performance/current-comparison | tee .build/folder-performance/current-comparison.txt

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
mkdir -p .build/folder-browser
swiftc -O -swift-version 5 -module-cache-path .build/module-cache \
    Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/FolderComparison.swift \
    Sources/CrossDiffCore/FolderBrowser.swift scripts/tests/FolderBrowserChecks.swift \
    -o .build/folder-browser/folder-browser-checks
.build/folder-browser/folder-browser-checks "$@"

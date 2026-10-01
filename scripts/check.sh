#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p .build/cache .build/config .build/security
swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security CrossDiffChecks

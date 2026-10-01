#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
swift scripts/make-icon.swift "$PWD/.build/brand/CrossDiff.iconset" --brand "$PWD/Resources/Brand"
swift scripts/pack-icon.swift "$PWD/.build/brand/CrossDiff.iconset" "$PWD/.build/brand/CrossDiff.icns"

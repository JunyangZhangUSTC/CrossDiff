#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
if [[ ! -x dist/CrossDiff.app/Contents/MacOS/CrossDiff ]]; then
  bash scripts/build-app.sh
fi
# Direct execution preserves the project-local environment, including sessions.
exec "$PWD/dist/CrossDiff.app/Contents/MacOS/CrossDiff"

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
bash scripts/check.sh
bash scripts/tests/check-editor.sh
bash scripts/tests/check-alignment.sh
bash scripts/tests/check-scroll-geometry.sh
bash scripts/tests/check-deletion-preview.sh
bash scripts/tests/check-workflow.sh

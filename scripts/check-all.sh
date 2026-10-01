#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh
python3 -m unittest discover -s scripts/tests -p 'test_github_release.py'
python3 -m unittest discover -s scripts/tests -p 'test_plugin_inventory.py'
bash scripts/check.sh
bash scripts/tests/check-archives-core.sh
bash scripts/tests/check-archive-plugin.sh
bash scripts/tests/check-binary-core.sh
bash scripts/tests/check-binary-detection.sh
bash scripts/tests/check-plugins-core.sh
bash scripts/tests/check-plugin-runtime.sh
bash scripts/tests/check-plugin-download.sh
bash scripts/tests/check-plugin-manager.sh
bash scripts/tests/check-official-plugins.sh
bash scripts/tests/check-pdf.sh
bash scripts/tests/check-image-comparison.sh
bash scripts/tests/check-editor.sh
bash scripts/tests/check-alignment.sh
bash scripts/tests/check-scroll-geometry.sh
bash scripts/tests/check-deletion-preview.sh
bash scripts/tests/check-workflow.sh
bash scripts/tests/check-new-comparison-workflow.sh
bash scripts/tests/check-image-workflow.sh
bash scripts/tests/check-plugin-workflow.sh
bash scripts/tests/check-official-plugin-ui.sh
bash scripts/tests/check-binary-workflow.sh
bash scripts/tests/check-archive-workflow.sh

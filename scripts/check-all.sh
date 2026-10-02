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
bash scripts/tests/check-photography-plugin.sh
bash scripts/tests/check-api-import.sh
bash scripts/tests/check-api-plugin.sh
bash scripts/tests/check-audio-plugin.sh
bash scripts/tests/check-audio-engine.sh
bash scripts/tests/check-audio-playback.sh
bash scripts/tests/check-audio-cache.sh
bash scripts/audio-research/build-matcher.sh
python3 scripts/audio-research/check-matcher.py
bash scripts/tests/check-photo-metadata.sh
bash scripts/tests/check-photo-engine.sh
bash scripts/tests/check-editor.sh
bash scripts/tests/check-alignment.sh
bash scripts/tests/check-newline-workflow.sh
bash scripts/tests/check-scroll-geometry.sh
bash scripts/tests/check-deletion-preview.sh
bash scripts/tests/check-workflow.sh
bash scripts/tests/check-new-comparison-workflow.sh
bash scripts/tests/check-folder-workflow.sh
bash scripts/tests/check-image-workflow.sh
bash scripts/tests/check-plugin-workflow.sh
bash scripts/tests/check-official-plugin-ui.sh
bash scripts/tests/check-binary-workflow.sh
bash scripts/tests/check-archive-workflow.sh
bash scripts/tests/check-photo-workflow.sh
bash scripts/tests/check-api-workflow.sh
bash scripts/tests/check-audio-workflow.sh

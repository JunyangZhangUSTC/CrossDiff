#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
python3 scripts/audio-research/verify-sources.py
mkdir -p .build/audio-research/bin
clang -O2 -std=gnu11 -I Sources/AudioMatchBridge/vendor \
  -ffile-prefix-map="$PWD"=. -fdebug-prefix-map="$PWD"=. \
  Sources/AudioMatchBridge/main.c Sources/AudioMatchBridge/vendor/*.c \
  -lm -lpthread -o .build/audio-research/bin/CrossDiffAudioMatcher

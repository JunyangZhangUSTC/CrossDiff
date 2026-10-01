#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
mkdir -p .build/audio-research/real
python3 -m venv .build/audio-research/venv
.build/audio-research/venv/bin/python -m pip install --disable-pip-version-check \
  --cache-dir .build/audio-research/pip-cache numpy==2.3.5 scipy==1.17.1 \
  docopt==0.6.2 joblib==1.5.3 psutil==7.2.2
curl -fL https://github.com/dpwe/audfprint/archive/cb03ba99feafd41b8874307f0f4e808a6ce34362.tar.gz -o .build/audio-research/audfprint.tar.gz
curl -fL https://librosa.org/data/audio/5703-47212-0000.ogg -o .build/audio-research/real/speech.ogg
curl -fL https://librosa.org/data/audio/Kevin_MacLeod_-_Vibe_Ace.ogg -o .build/audio-research/real/music.ogg
curl -fL https://librosa.org/data/audio/5703-47212-0000.txt -o .build/audio-research/real/speech-license.txt
curl -fL https://librosa.org/data/audio/Kevin_MacLeod_-_Vibe_Ace.txt -o .build/audio-research/real/music-license.txt
python3 - <<'PY'
from pathlib import Path
import hashlib
expected={
 'audfprint.tar.gz':'7fa07bada480cd0e65379780ce8b37facbce93bbacf7eb0b9486f017c7b8936e',
 'real/music.ogg':'6c23aed3dd5aa57f2b1652ecab68d15d9b82ad257f54e639eb2880ca09bc118a',
 'real/speech.ogg':'a284612b46af0535f7e1873758c4387bb8369f6dbbe192ffdec1f171108f98dd'}
for name,digest in expected.items():
 if hashlib.sha256((Path('.build/audio-research')/name).read_bytes()).hexdigest()!=digest:raise SystemExit('Hash mismatch: '+name)
PY
tar -xzf .build/audio-research/audfprint.tar.gz -C .build/audio-research
# Research uses an already available ffmpeg; it is never installed or bundled here.
command -v ffmpeg >/dev/null
bash scripts/audio-research/build-matcher.sh

#!/bin/bash
# Research-only: no Java/global install, no alteration of HOME.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/project-env.sh
mkdir -p .build/audio-research/jdk17 .build/audio-research/java-home .build/audio-research/java-classes .build/audio-research/panako-current-classes
curl -fL 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.16%2B8/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.16_8.tar.gz' -o .build/audio-research/jdk17.tar.gz
curl -fL https://github.com/JorenSix/Panako/releases/download/joss/Panako-2.1-all.jar -o .build/audio-research/Panako-2.1-all.jar
curl -fL https://mvn.0110.be/releases/be/ugent/jgaborator/jgaborator/0.7/jgaborator-0.7.jar -o .build/audio-research/jgaborator-0.7.jar
curl -fL https://github.com/JorenSix/Panako/archive/f1248f7a35a06af449f02f7df33c4cfdc1aeedc1.tar.gz -o .build/audio-research/panako-source.tar.gz
python3 - <<'PY'
import hashlib
from pathlib import Path
expected={
 'jdk17.tar.gz':'f9845abc8403f1d489402201064e7b9f2c57605d8717b85a95a15d94f882eeb7',
 'Panako-2.1-all.jar':'767cdd2cd0991658c4a25a0b8e887f9a2a38f69ae17781b02fe1652e1a7173d4',
 'jgaborator-0.7.jar':'5001609d4e9d71853d24053a19bbe71b8d19ffc11e57f3149241745b8774df70',
 'panako-source.tar.gz':'e8b56fc7cc8b54ad41ff3d3815944ccaaf669468dc506feec3b55f4303959340'}
for name,digest in expected.items():
 if hashlib.sha256((Path('.build/audio-research')/name).read_bytes()).hexdigest()!=digest:raise SystemExit('Hash mismatch: '+name)
PY
tar -xzf .build/audio-research/jdk17.tar.gz -C .build/audio-research/jdk17 --strip-components=1
tar -xzf .build/audio-research/panako-source.tar.gz -C .build/audio-research
python3 - <<'PY'
from pathlib import Path
import subprocess
p=Path('.build/audio-research')
javac=p/'jdk17/Contents/Home/bin/javac'
cp=str(p/'jgaborator-0.7.jar')+':'+str(p/'Panako-2.1-all.jar')
sources=sorted((p/'Panako-f1248f7a35a06af449f02f7df33c4cfdc1aeedc1/src/main/java').rglob('*.java'))
jvm=['-J-XX:-UsePerfData','-J-Duser.home='+str((p/'java-home').resolve()),'-J-Djava.io.tmpdir='+str(Path('.build/tmp').resolve())]
subprocess.run([str(javac),*jvm,'--release','11','-cp',cp,'-d',str(p/'panako-current-classes'),*map(str,sources)],check=True)
subprocess.run([str(javac),*jvm,'-cp',cp,'-d',str(p/'java-classes'),'scripts/audio-research/PanakoPair.java'],check=True)
PY

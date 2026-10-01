#!/usr/bin/env python3
"""Runs the explicit Panako strategy against the same real excerpts as Olaf/audfprint."""
from pathlib import Path
import json
import subprocess

ROOT=Path(__file__).resolve().parents[2]
WORK=ROOT/'.build/audio-research'
REAL=WORK/'real'


def run_pair(reference,queries,name):
    java=WORK/'jdk17/Contents/Home/bin/java'
    cp=':'.join(str(WORK/x) for x in ['java-classes','panako-current-classes','jgaborator-0.7.jar','Panako-2.1-all.jar'])
    args=[str(java),'-XX:-UsePerfData','-Duser.home='+str(WORK/'java-home'),'-Djava.io.tmpdir='+str(ROOT/'.build/tmp'),
          '-Djava.library.path='+str(WORK/'native'),'-cp',cp,'PanakoPair',str(reference),*map(str,queries)]
    r=subprocess.run(args,capture_output=True,timeout=120,cwd=WORK)
    if r.returncode:raise RuntimeError(r.stderr.decode())
    (WORK/(name+'.log')).write_bytes(r.stdout)
    (WORK/(name+'.err')).write_bytes(r.stderr)
    return r.stdout.decode()


def main():
    names=['trim','tempo-1.1','pitch-1.1','speed-1.1','independent-tempo-1.15-pitch-0.95']
    report={}
    for kind in ['music','speech']:
        report[kind+'10']=run_pair(REAL/(kind+'.ogg'),[REAL/(kind+'-'+name+'.wav') for name in names],'panako-current-'+kind)
    filters={'trim':'anull','tempo':'atempo=1.1','pitch':'asetrate=17600,aresample=16000,atempo=0.9090909091',
             'speed':'asetrate=17600,aresample=16000','independent':'asetrate=15200,aresample=16000,atempo=1.210526316'}
    subprocess.run(['ffmpeg','-v','error','-ss','20','-t','20','-i',str(REAL/'music.ogg'),'-ar','16000','-ac','1','-y',str(REAL/'music20-source.wav')],check=True)
    for name,f in filters.items():
        subprocess.run(['ffmpeg','-v','error','-i',str(REAL/'music20-source.wav'),'-af',f,'-ar','16000','-ac','1','-y',str(REAL/f'music20-{name}.wav')],check=True)
    report['music20']=run_pair(REAL/'music.ogg',[REAL/f'music20-{name}.wav' for name in filters],'panako-current-music20')
    (WORK/'panako-benchmark.json').write_text(json.dumps(report,indent=2)+'\n')
    for case,log in report.items():print(case+'\n'+log)


if __name__=='__main__':main()

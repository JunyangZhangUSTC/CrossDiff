#!/usr/bin/env python3
"""Small provenance-labelled experiment, not a general accuracy benchmark.

Run after prepare-benchmarks.sh. All transformed excerpts stay under .build.
"""
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.build/audio-research'
REAL = WORK / 'real'
HELPER = WORK / 'bin/CrossDiffAudioMatcher'
PYTHON = WORK / 'venv/bin/python'
AUDFPRINT = WORK / 'audfprint-cb03ba99feafd41b8874307f0f4e808a6ce34362/audfprint.py'


def run(args):
    p = subprocess.run([str(a) for a in args], capture_output=True, timeout=120)
    if p.returncode:
        raise RuntimeError(p.stderr.decode() or p.stdout.decode())
    return p.stdout.decode()


def main():
    report = {'description': 'Two CC-BY recordings, 10-second excerpts; sample observations, not calibrated accuracy', 'sources': {}, 'results': []}
    filters = {'trim': 'anull', 'tempo-1.1': 'atempo=1.1',
               'pitch-1.1': 'asetrate=17600,aresample=16000,atempo=0.9090909091',
               'speed-1.1': 'asetrate=17600,aresample=16000',
               'independent-tempo-1.15-pitch-0.95': 'asetrate=15200,aresample=16000,atempo=1.210526316'}
    for kind in ['music', 'speech']:
        original = REAL / (kind + '.ogg')
        report['sources'][kind] = {'sha256': hashlib.sha256(original.read_bytes()).hexdigest()}
        raw = REAL / (kind + '.pcm')
        run(['ffmpeg', '-v', 'error', '-i', original, '-ar', '16000', '-ac', '1', '-f', 'f32le', '-y', raw])
        db = WORK / ('audfprint-' + kind + '.pklz')
        run([PYTHON, AUDFPRINT, 'new', '--dbase', db, '--maxtimebits', '20', original])
        for variant, filter_spec in filters.items():
            wav = REAL / (kind + '-' + variant + '.wav')
            pcm = wav.with_suffix('.pcm')
            run(['ffmpeg', '-v', 'error', '-ss', '2', '-t', '10', '-i', original, '-ar', '16000', '-ac', '1', '-y', REAL/'excerpt.wav'])
            run(['ffmpeg', '-v', 'error', '-i', REAL/'excerpt.wav', '-af', filter_spec, '-ar', '16000', '-ac', '1', '-y', wav])
            run(['ffmpeg', '-v', 'error', '-i', wav, '-ar', '16000', '-ac', '1', '-f', 'f32le', '-y', pcm])
            start = time.monotonic()
            with tempfile.TemporaryDirectory(dir=WORK) as task:
                native = json.loads(run([HELPER, raw, pcm, task]))
            elapsed = time.monotonic() - start
            baseline = run([PYTHON, AUDFPRINT, 'match', '--dbase', db, '--find-time-range', '--max-matches', '20', wav])
            report['results'].append({'source': kind, 'variant': variant, 'olaf': native,
                                      'olafSeconds': elapsed, 'audfprintLog': baseline})
            if variant == 'trim':
                assert native['matches'], kind + ' trim was not found'
                assert 'Matched' in baseline, kind + ' audfprint trim was not found'
    (WORK/'real-benchmark.json').write_text(json.dumps(report, indent=2)+'\n')
    for result in report['results']:
        print(result['source'], result['variant'], 'Olaf candidates:', len(result['olaf']['matches']),
              'audfprint matched:', 'Matched' in result['audfprintLog'])


if __name__ == '__main__':
    main()

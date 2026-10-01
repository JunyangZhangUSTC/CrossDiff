#!/usr/bin/env python3
"""Deterministic integration checks against the pinned native Olaf implementation."""
import array
import hashlib
import json
import math
import random
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.build/audio-research/checks'
HELPER = ROOT / '.build/audio-research/bin/CrossDiffAudioMatcher'
RATE = 16000


def signal(seed, seconds=48):
    rng = random.Random(seed)
    # Original, deterministic multivoice tones and percussive events: no external recording.
    notes = [(rng.uniform(160, 1300), rng.uniform(0.10, 0.8), rng.random() * 6.28)
             for _ in range(seconds * 8 + 8)]
    values = array.array('f')
    for i in range(seconds * RATE):
        t = i / RATE
        cell = int(t * 8)
        x = 0
        for v in range(3):
            freq, decay, phase = notes[(cell // (v + 1) * (v + 1) + v) % len(notes)]
            beat = t % ((v + 1) / 8)
            envelope = math.exp(-beat / decay)
            x += 0.16 * envelope * math.sin(2 * math.pi * freq * t + phase)
        x += rng.uniform(-0.008, 0.008)
        values.append(x)
    return values


def save(name, values):
    p = WORK / (name + '.pcm')
    p.write_bytes(values.tobytes())
    return p


def compare(left, right):
    with tempfile.TemporaryDirectory(dir=WORK) as task:
        r = subprocess.run([str(HELPER), str(left), str(right), task], capture_output=True, timeout=30)
        assert r.returncode == 0, r.stderr.decode()
        return json.loads(r.stdout)


def supports(pairs, l, r, minimum=2):
    return any(min(p['leftEnd'], l[1]) - max(p['leftStart'], l[0]) >= minimum
               and min(p['rightEnd'], r[1]) - max(p['rightStart'], r[0]) >= minimum
               and abs((p['rightStart'] - p['leftStart']) - (r[0] - l[0])) < 0.08 for p in pairs)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    source = signal(918)
    left = save('source', source)
    original_hash = hashlib.sha256(left.read_bytes()).hexdigest()
    cases = {
        'same': (source, [((0, 48), (0, 48))]),
        'trim': (source[10*RATE:27*RATE], [((10, 27), (0, 17))]),
        'reorder': (source[27*RATE:39*RATE] + source[4*RATE:16*RATE], [((27, 39), (0, 12)), ((4, 16), (12, 24))]),
        'repeat': (source[9*RATE:21*RATE] * 2, [((9, 21), (0, 12)), ((9, 21), (12, 24))]),
        'tail': (signal(654, 12) + source[35*RATE:43*RATE], [((35, 43), (12, 20))]),
        'gain': (array.array('f', (x*0.35 for x in source[5*RATE:20*RATE])), [((5, 20), (0, 15))]),
        'different': (signal(43, 20), []),
        'silence': (array.array('f', [0])*20*RATE, []),
    }
    report = {}
    for name, (values, expected) in cases.items():
        result = compare(left, save(name, values))
        found = result['matches']
        for l, r in expected:
            assert supports(found, l, r), (name, l, r, found)
        if not expected:
            assert not found, (name, found)
        report[name] = result
    assert hashlib.sha256(left.read_bytes()).hexdigest() == original_hash
    short = compare(left, save('short', source[:RATE]))
    assert short['partial'] and not short['matches'], short
    # A window can fill Olaf's 64-result shortlist with many <2-second
    # repetitions. Even though none is displayable, the bounded search must
    # report partial rather than hide the shortlist limit after filtering.
    motif = source[:3*RATE//2]
    repeated = save('short-repetitions', (motif + array.array('f', [0])*(RATE//2))*80)
    probe = save('short-repetition-probe', motif + array.array('f', [0])*(3*RATE//2))
    limited = compare(repeated, probe)
    assert limited['partial'] and not limited['matches'], limited
    report['short_repetition_limit'] = limited
    # Invalid input exits rather than entering the fingerprint engine.
    invalid = WORK / 'invalid.pcm'; invalid.write_bytes(b'bad')
    with tempfile.TemporaryDirectory(dir=WORK) as task:
        assert subprocess.run([str(HELPER), str(left), str(invalid), task], capture_output=True).returncode != 0
    # A named pipe must reject promptly without waiting for a writer.
    import os
    fifo = WORK/'input.fifo'
    if fifo.exists(): fifo.unlink()
    os.mkfifo(fifo)
    try:
        with tempfile.TemporaryDirectory(dir=WORK) as task:
            assert subprocess.run([str(HELPER), str(left), str(fifo), task], capture_output=True, timeout=2).returncode != 0
    finally:
        fifo.unlink()
    (WORK/'results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'{len(cases)} native matching cases passed; source preserved; short input and capped short repetitions partial; malformed PCM and FIFO rejected')


if __name__ == '__main__':
    main()

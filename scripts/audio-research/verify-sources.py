#!/usr/bin/env python3
"""Verify the pinned source set and explicitly recorded integration patches."""
from pathlib import Path
import hashlib
import json

root=Path(__file__).resolve().parents[2]
lock=json.loads((root/'ThirdParty/AudioMatching/source-lock.json').read_text())
vendor=root/'Sources/AudioMatchBridge/vendor'
assert set(p.name for p in vendor.iterdir())==set(lock['files']), 'Unexpected or missing vendored files'
for name,upstream in lock['files'].items():
    expected=lock.get('patches',{}).get(name,{}).get('sha256',upstream)
    actual=hashlib.sha256((vendor/name).read_bytes()).hexdigest()
    if actual!=expected:raise SystemExit('Vendored audio source hash mismatch: '+name)
print('Pinned Olaf source and documented integration patch verified')

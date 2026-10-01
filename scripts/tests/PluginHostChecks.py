#!/usr/bin/env python3
"""Exercise the helper's public stdin/stdout contract using a real script."""
import json
import subprocess
import sys


helper = sys.argv[1]
request = {
    "protocolVersion": 1,
    "runID": "independent-algorithm",
    "mode": "pairwise",
    "inputs": [
        {"id": "left", "role": "left", "name": "left", "content": "aab"},
        {"id": "right", "role": "right", "name": "right", "content": "bcc"},
    ],
    "options": {},
}
script = """
function compare(request) {
    const left = new Set(Array.from(request.inputs[0].content));
    const right = new Set(Array.from(request.inputs[1].content));
    return {
        protocolVersion: 1, runID: request.runID, schema: 'crossdiff.table/1',
        status: 'completed', summary: {zhHans: '字符集合', en: 'Character sets'},
        diagnostics: [], payload: {
            leftOnly: Array.from(left).filter(value => !right.has(value)),
            rightOnly: Array.from(right).filter(value => !left.has(value))
        }
    };
}
"""
completed = subprocess.run(
    [helper], input=json.dumps({"script": script, "request": request}).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=True,
)
result = json.loads(completed.stdout)
assert result["payload"] == {"leftOnly": ["a"], "rightOnly": ["c"]}, result
assert result["runID"] == "independent-algorithm", result
print("PASS: independent JavaScript algorithm executes through helper JSON contract")

probe = """
function compare(request) {
    const names = ['require', 'load', 'readFile', 'fetch', 'XMLHttpRequest',
        'process', 'FileHandle', 'NSFileManager', 'ObjC', 'Deno', 'Bun'];
    return {available: names.filter(name => typeof globalThis[name] !== 'undefined')};
}
"""
completed = subprocess.run(
    [helper], input=json.dumps({"script": probe, "request": request}).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=True,
)
assert json.loads(completed.stdout) == {"available": []}, completed.stdout
print("PASS: restricted JS has no filesystem, network, module or native bridge globals")

completed = subprocess.run(
    [helper], input=json.dumps({"script": "function compare() { return 'x'.repeat(9 * 1024 * 1024); }", "request": request}).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
)
assert completed.returncode != 0 and not completed.stdout, "oversized output escaped helper bound"
assert len(completed.stderr) <= 1024
print("PASS: helper rejects oversized output before writing stdout")

large_request = dict(request, options={"padding": "x" * (33 * 1024 * 1024)})
completed = subprocess.run(
    [helper], input=json.dumps({"script": script, "request": large_request}).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
)
assert completed.returncode != 0 and not completed.stdout, "oversized input was accepted"
print("PASS: helper rejects oversized stdin")

completed = subprocess.run(
    [helper], input=json.dumps({"script": "function compare() { for (;;) {} }", "request": request,
                              "cpuTimeLimitSeconds": 1}).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3,
)
assert completed.returncode != 0 and not completed.stdout
print("PASS: helper CPU limit stops an infinite script without a parent watchdog")

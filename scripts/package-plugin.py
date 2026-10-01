#!/usr/bin/env python3
"""Package an experimental CrossDiff plugin reproducibly (no third-party dependencies)."""
import argparse
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Directory containing manifest.json and compare.js (or plugin executable)")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
source, output = args.source.resolve(), args.output.resolve()
if root not in source.parents or root not in output.parents:
    parser.error("All development inputs and outputs must stay inside this project.")
manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
package = {"formatVersion": 1, "manifest": manifest}
if manifest["runtime"] == "restrictedJavaScript":
    payload = (source / "compare.js").read_bytes()
    package["script"] = payload.decode("utf-8")
elif manifest["runtime"] == "trustedExecutable":
    import base64
    payload = (source / "plugin").read_bytes()
    package["executable"] = base64.b64encode(payload).decode("ascii")
else:
    parser.error("Unknown runtime")
package["sha256"] = hashlib.sha256(payload).hexdigest()
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(package, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(output.relative_to(root))

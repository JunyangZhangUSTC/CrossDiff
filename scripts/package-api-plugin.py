#!/usr/bin/env python3
"""Package the official API algorithm deterministically, without third-party dependencies."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "dist" / "Plugins" / "API.crossdiffplugin")
    output = parser.parse_args().output.resolve()
    if root not in output.parents:
        parser.error("Development package output must remain inside the project.")
    source = root / "Plugins" / "Official" / "API"
    script = (source / "compare.js").read_text(encoding="utf-8")
    package = {
        "formatVersion": 1,
        "manifest": json.loads((source / "manifest.json").read_text(encoding="utf-8")),
        "script": script,
        "sha256": hashlib.sha256(script.encode("utf-8")).hexdigest(),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(package, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(output.relative_to(root))


if __name__ == "__main__":
    main()

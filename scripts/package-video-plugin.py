#!/usr/bin/env python3
"""Package the official video metadata plugin using the release inventory's exact bytes."""
import argparse
from pathlib import Path

from plugin_inventory import ROOT, build_inventory, project_output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/Plugins/Video.crossdiffplugin")
    args = parser.parse_args()
    try:
        output = project_output(args.output)
        # Package bytes are independent of the app release tag used for catalog links.
        _, packages = build_inventory("0.14.0")
        contents = next(data for name, data in packages.items() if name.startswith("CrossDiff-Plugin-Video-"))
        if args.output.is_symlink():
            raise ValueError("Refusing a symlink as a generated package.")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(contents)
        print(output.relative_to(ROOT))
    except (ValueError, OSError, StopIteration) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

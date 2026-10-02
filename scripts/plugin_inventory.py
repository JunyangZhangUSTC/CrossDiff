#!/usr/bin/env python3
"""One deterministic inventory for app editions, release packages and the offline catalog."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "JunyangZhangUSTC/CrossDiff"
APP_LICENSE_FILES = ("LICENSE", "NOTICE", "ThirdParty/OpenCV/LICENSE",
                     "ThirdParty/OpenCV/COPYRIGHT", "ThirdParty/OpenCV/NOTICE.md",
                     "ThirdParty/OpenCV/NOTICE-SOURCE.txt", "ThirdParty/OpenCV/SoftFloat-COPYING.txt",
                     "ThirdParty/AudioMatching/LICENSE-Olaf.txt", "ThirdParty/AudioMatching/LICENSE-LMDB.txt",
                     "ThirdParty/AudioMatching/NOTICE-pffft.c.txt", "ThirdParty/AudioMatching/NOTICE-hash-table.c.txt",
                     "ThirdParty/AudioMatching/NOTICE-midl.c.txt", "ThirdParty/AudioMatching/NOTICE-mdb.c.txt",
                     "ThirdParty/AudioMatching/NOTICE-queue.c.txt", "ThirdParty/AudioMatching/source-lock.json",
                     "ThirdParty/AudioMatching/README.md")
# Explicit inventory: adding an example never silently adds it to a production edition.
PLUGINS = (
    {"source": "Plugins/Official/Archive", "id": "org.crossdiff.archive", "label": "Archive", "official": True,
     "bundled": "dev.crossdiff.archive.crossdiffplugin", "editions": ("base", "full")},
    {"source": "Plugins/PDF", "id": "org.crossdiff.pdf", "label": "PDF", "official": True,
     "bundled": "dev.crossdiff.pdf.crossdiffplugin", "editions": ("full",)},
    {"source": "Plugins/Official/Photography", "id": "org.crossdiff.photography", "label": "Photography", "official": True,
     "bundled": "dev.crossdiff.photography.crossdiffplugin", "editions": ("full",)},
    {"source": "Plugins/Official/API", "id": "org.crossdiff.api", "label": "API", "official": True,
     "bundled": "dev.crossdiff.api.crossdiffplugin", "editions": ("full",)},
    {"source": "Plugins/Official/Audio", "id": "org.crossdiff.audio", "label": "Audio", "official": True,
     "bundled": "dev.crossdiff.audio.crossdiffplugin", "editions": ("full",)},
    {"source": "Plugins/Official/Office", "id": "org.crossdiff.office", "label": "Office", "official": True,
     "bundled": "dev.crossdiff.office.crossdiffplugin", "editions": ("full",)},
    {"source": "Plugins/Examples/JSON", "id": "example.crossdiff.json-keys", "label": "JSON", "official": False,
     "bundled": None, "editions": ()},
)


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def valid_version(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value) is not None


def build_inventory(version: str, read=None) -> tuple[bytes, dict[str, bytes]]:
    """read accepts a repository-relative path, allowing validation against committed source."""
    if not valid_version(version):
        raise ValueError("Expected an app release version in X.Y.Z format.")
    read = read or (lambda path: (ROOT / path).read_bytes())
    packages, entries = {}, []
    for definition in PLUGINS:
        manifest = json.loads(read(definition["source"] + "/manifest.json"))
        if manifest.get("id") != definition["id"] or not valid_version(manifest.get("version")):
            raise ValueError("Plugin manifest identity or version does not match the release inventory.")
        if manifest.get("runtime") != "restrictedJavaScript":
            raise ValueError("Bundled official plugins and examples must use the restricted runtime.")
        for key in ("name", "summary"):
            if (not isinstance(manifest.get(key), dict)
                    or any(not isinstance(manifest[key].get(locale), str) or not manifest[key][locale].strip()
                           for locale in ("zhHans", "en"))):
                raise ValueError("Plugin metadata must include nonempty Chinese and English text.")
        # Match the standalone packagers' UTF-8 text newline normalization.
        script = read(definition["source"] + "/compare.js").decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        package = json_bytes({"formatVersion": 1, "manifest": manifest, "script": script,
                              "sha256": hashlib.sha256(script.encode("utf-8")).hexdigest()})
        category = "Plugin" if definition["official"] else "Example"
        asset = f"CrossDiff-{category}-{definition['label']}-{manifest['version']}.crossdiffplugin"
        packages[asset] = package
        if definition["official"]:
            entries.append({"id": manifest["id"], "version": manifest["version"], "name": manifest["name"],
                            "summary": manifest["summary"], "asset": asset,
                            "url": f"https://github.com/{REPOSITORY}/releases/download/v{version}/{asset}",
                            "sha256": hashlib.sha256(package).hexdigest(), "size": len(package)})
    return json_bytes({"formatVersion": 1, "releaseTag": f"v{version}", "plugins": entries}), packages


def validate_catalog(catalog: bytes, packages: dict[str, bytes], version: str, read=None):
    expected_catalog, expected_packages = build_inventory(version, read)
    if catalog != expected_catalog or packages != expected_packages:
        raise ValueError("Release catalog or plugin assets differ from the committed plugin inventory.")


def bundle_inventory(edition: str, packages: dict[str, bytes]) -> dict[str, bytes]:
    if edition not in {"base", "full"}:
        raise ValueError("Unknown application edition.")
    result = {}
    for definition in PLUGINS:
        if edition in definition["editions"]:
            matches = [contents for asset, contents in packages.items()
                       if asset.startswith(f"CrossDiff-Plugin-{definition['label']}-")]
            if len(matches) != 1:
                raise ValueError("Missing or ambiguous bundled plugin package.")
            result[definition["bundled"]] = matches[0]
    return result


def validate_app_archive(path: Path, edition: str, catalog: bytes, packages: dict[str, bytes], metadata: dict):
    prefix = "CrossDiff.app/Contents/"
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if not names or len(names) != len(set(names)):
            raise ValueError("Empty app archive or duplicate entries.")
        for entry in archive.infolist():
            parts = PurePosixPath(entry.filename).parts
            if (not entry.filename.startswith("CrossDiff.app/") or ".." in parts or "__MACOSX" in parts
                    or any(part.startswith("._") for part in parts) or entry.extra or entry.comment):
                raise ValueError("Unsafe app archive entry or personal ZIP metadata.")
        if plistlib.loads(archive.read(prefix + "Info.plist")) != metadata:
            raise ValueError("Application metadata differs from the release source.")
        for notice in APP_LICENSE_FILES:
            if prefix + "Resources/" + notice not in names:
                raise ValueError("Missing application license notice.")
        if archive.read(prefix + "Resources/OfficialPlugins.json") != catalog:
            raise ValueError("Application catalog differs from plugins.json.")
        plugin_prefix = prefix + "Resources/Plugins/"
        actual = {name.removeprefix(plugin_prefix): archive.read(name) for name in names
                  if name.startswith(plugin_prefix) and not name.endswith("/")}
        if actual != bundle_inventory(edition, packages):
            raise ValueError("Application edition contains the wrong plugin packages.")


def project_output(path: Path) -> Path:
    result = path.resolve()
    if ROOT not in result.parents:
        raise ValueError("All generated output must remain inside the project.")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--output", type=Path, help="Write all release plugin assets and plugins.json here.")
    parser.add_argument("--bundle-resources", type=Path, help="Write this edition's Plugins/ and OfficialPlugins.json here.")
    parser.add_argument("--edition", choices=("base", "full"), default="full")
    args = parser.parse_args()
    if bool(args.output) == bool(args.bundle_resources):
        parser.error("Choose exactly one of --output or --bundle-resources.")
    try:
        version = args.version or plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
        catalog, packages = build_inventory(version)
        if args.output:
            output = project_output(args.output)
            output.mkdir(parents=True, exist_ok=True)
            for name, data in {**packages, "plugins.json": catalog}.items():
                destination = output / name
                if destination.is_symlink():
                    raise ValueError("Refusing a symlink as a generated asset.")
                destination.write_bytes(data)
        else:
            output = project_output(args.bundle_resources)
            output.mkdir(parents=True, exist_ok=True)
            plugin_dir = output / "Plugins"
            if plugin_dir.is_symlink() or (output / "OfficialPlugins.json").is_symlink():
                raise ValueError("Refusing symlinked bundle resources.")
            if plugin_dir.exists():
                shutil.rmtree(plugin_dir)
            plugin_dir.mkdir()
            for name, data in bundle_inventory(args.edition, packages).items():
                (plugin_dir / name).write_bytes(data)
            (output / "OfficialPlugins.json").write_bytes(catalog)
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

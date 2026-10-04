#!/bin/bash
# Verify the actual Base/Full bundles; never build a substitute helper or launch the GUI.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: bash scripts/tests/check-bundled-helpers.sh [Base.app Full.app]\n'
  printf 'Defaults: dist/editions/base/CrossDiff.app and dist/CrossDiff.app. Verify signatures separately.\n'
  exit 0
fi
if [[ $# == 0 ]]; then
  set -- "$project_root/dist/editions/base/CrossDiff.app" "$project_root/dist/CrossDiff.app"
fi
if [[ $# != 2 ]]; then
  printf 'Provide both the Base and Full .app paths, in that order.\n' >&2
  exit 2
fi
python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile

ROOT = Path.cwd().resolve()
sys.path.insert(0, str(ROOT / "scripts"))
import plugin_inventory as inventory


def require(condition, message):
    if not condition:
        raise ValueError(message)


def bundle(argument, edition):
    path = Path(argument).resolve()
    require(ROOT in path.parents and path.suffix == ".app", "Bundle must be an .app inside this project.")
    contents = path / "Contents"
    app_architectures = None
    for name in inventory.APP_EXECUTABLE_FILES:
        executable = contents / name
        require(path in executable.resolve().parents, f"{edition}: executable leaves its bundle: {name}")
        info = executable.lstat()
        with executable.open("rb") as source:
            inventory.validate_app_executable(name, info.st_mode, info.st_size, source.read(32))
        require(os.access(executable, os.X_OK), f"{edition}: executable cannot be run: {name}")
        architecture_check = subprocess.run(["/usr/bin/lipo", "-archs", str(executable)],
                                            check=True, capture_output=True, text=True, timeout=10)
        architectures = set(architecture_check.stdout.split())
        require(bool(architectures) and architectures <= {"arm64", "x86_64"},
                f"{edition}: unsupported executable architectures: {name}: {sorted(architectures)}")
        if name == "MacOS/CrossDiff":
            app_architectures = architectures
        else:
            require(architectures == app_architectures,
                    f"{edition}: helper architectures differ from the application: {name}: {sorted(architectures)} vs {sorted(app_architectures or [])}")
    metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    expected_metadata = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    require(metadata == expected_metadata, f"{edition}: bundle metadata is stale; build this source first.")
    catalog, packages = inventory.build_inventory(metadata["CFBundleShortVersionString"])
    resources = contents / "Resources"
    require((resources / "OfficialPlugins.json").read_bytes() == catalog, f"{edition}: stale plugin catalog.")
    actual = {item.name: item.read_bytes() for item in (resources / "Plugins").iterdir() if item.is_file()}
    require(actual == inventory.bundle_inventory(edition, packages), f"{edition}: wrong bundled plugins.")
    return contents / "Helpers/CrossDiffArchiveReader"


def expected_entries(folder):
    result = {}
    for path in sorted(folder.rglob("*")):
        name = path.relative_to(folder).as_posix()
        if path.is_symlink():
            result[name] = {"kind": "symbolicLink", "issue": "symbolicLink"}
        elif path.is_dir():
            result[name] = {"kind": "directory", "size": 0}
        else:
            data = path.read_bytes()
            result[name] = {"kind": "file", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    return result


def work_snapshot(work, reply):
    """Include the helper's cwd, not just its inputs; ignore only its stdout file."""
    result = {}
    for path in [work, *sorted(work.rglob("*"))]:
        if path == reply:
            continue
        info = path.lstat()
        # Reads can change atime. Other metadata and bytes must remain unchanged,
        # including directory metadata if files were extracted and removed again.
        stamp = (info.st_mode, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if stat.S_ISLNK(info.st_mode):
            contents = os.readlink(path)
        elif stat.S_ISDIR(info.st_mode):
            contents = None
        else:
            require(stat.S_ISREG(info.st_mode), f"Unexpected special file in helper work directory: {path.name}")
            contents = hashlib.sha256(path.read_bytes()).hexdigest()
        result[path.relative_to(work).as_posix()] = (stamp, contents)
    return result


def read(helper, source, output):
    # Exactly the shipping helper protocol: inherited read-only descriptor plus
    # a path for identity verification. No CROSSDIFF_ARCHIVE_READER override.
    digest = hashlib.sha256(source.read_bytes()).digest()
    with source.open("rb") as input_file, output.open("w+b") as reply_file:
        completed = subprocess.run([str(helper), "--read", str(source)], stdin=input_file,
                                   stdout=reply_file, stderr=subprocess.PIPE,
                                   cwd=output.parent, timeout=65,
                                   env={"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"})
        require(completed.returncode == 0, f"{source.name}: helper exited {completed.returncode}.")
        size = reply_file.tell()
        require(0 < size <= 16 * 1024 * 1024, f"{source.name}: invalid helper reply size.")
        reply_file.seek(0)
        value = json.load(reply_file)
    require(hashlib.sha256(source.read_bytes()).digest() == digest, f"{source.name}: helper changed source bytes.")
    require(isinstance(value, dict), f"{source.name}: invalid reply object.")
    return value


def run():
    helpers = [(edition, bundle(path, edition)) for edition, path in zip(("base", "full"), sys.argv[1:])]
    require(helpers[0][1] != helpers[1][1], "Base and Full must be separate application bundles.")
    checks = ROOT / ".build/tests/bundled-helpers"
    checks.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=checks) as temporary:
        work = Path(temporary)
        fixtures = work / "fixtures"
        subprocess.run([sys.executable, "scripts/tests/fixtures/archive-native/generate.py", str(fixtures)],
                       cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        positives = [(name, "folder") for name in ("copy.7z", "lzma1.7z", "lzma2.7z", "solid.7z", "header-compressed.7z")]
        positives += [("test_read_format_rar.rar", "rar4-stored"),
                      ("test_read_format_rar5_stored.rar", "rar5-stored"),
                      ("test_read_format_rar5_compressed.rar", "rar5-compressed"),
                      ("test_read_format_rar5_multiple_files_solid.rar", "rar5-solid")]
        damaged = ("bad-payload-crc-copy.7z", "bad-tail-header-compressed.7z",
                   "bad-truncated-test_read_format_rar.rar", "bad-payload-crc-test_read_format_rar5_stored.rar")
        # Freeze the expected content before any helper can touch the fixture tree.
        expected_by_directory = {directory: expected_entries(fixtures / directory)
                                 for directory in {directory for _, directory in positives}}
        reply = work / "reply.json"
        reply.touch()  # Subsequent stdout writes must not add entries to the cwd.
        original_work = work_snapshot(work, reply)
        for edition, helper in helpers:
            for name, directory in positives:
                value = read(helper, fixtures / name, reply)
                require(value.get("error") is None, f"{edition}/{name}: rejected: {value.get('error')}")
                entries = value.get("entries")
                require(isinstance(entries, list), f"{edition}/{name}: missing entries.")
                actual = {entry["path"]: entry for entry in entries}
                expected = expected_by_directory[directory]
                require(len(entries) == len(actual) and actual.keys() == expected.keys(), f"{edition}/{name}: wrong paths.")
                for path, record in expected.items():
                    entry = actual[path]
                    require(all(entry.get(key) == data for key, data in record.items()), f"{edition}/{name}/{path}: wrong content.")
                    if record["kind"] == "symbolicLink":
                        require(entry.get("sha256") is None, f"{edition}/{name}: followed a symbolic link.")
                    else:
                        require(entry.get("issue") is None, f"{edition}/{name}: unexpectedly unverified content.")
                require(value.get("totalExpandedBytes") == sum(entry["size"] for entry in entries), f"{edition}/{name}: wrong total.")
            for name in damaged:
                value = read(helper, fixtures / name, reply)
                require(isinstance(value.get("error"), dict) and "damaged" in value["error"], f"{edition}/{name}: missing corruption rejection.")
                require(value.get("entries") is None and value.get("totalExpandedBytes") is None, f"{edition}/{name}: published partial content.")
            require(work_snapshot(work, reply) == original_work,
                    f"{edition}: helper changed, extracted or removed files outside its reply in the work directory.")
            print(f"PASS: {edition} bundle, four architecture-matched executables, {len(positives)} real archives, {len(damaged)} corruption rejections and unchanged work tree")


try:
    run()
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
    sys.exit(f"FAIL: bundled helper verification: {error}")
PY

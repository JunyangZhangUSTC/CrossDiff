"""Deterministic, project-local fixtures for the native archive workflow."""
import io
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import zipfile

project = Path(__file__).resolve().parents[2]
root = Path(sys.argv[1]).resolve()
assert root.is_relative_to(project) and root.name == "fixtures"
if root.exists():
    shutil.rmtree(root)
root.mkdir(parents=True)
left = {"docs/common.txt": b"CrossDiff local comparison\n", "docs/changed.txt": b"version 1\n",
        "empty/": b"", "removed.txt": b"left only", "kind": b"file before directory",
        "old-name.dat": b"identical content\x00\x01", "copies/duplicate.dat": b"identical content\x00\x01",
        "说明/本地.txt": "保留中文路径".encode()}
right = {"docs/common.txt": left["docs/common.txt"], "docs/changed.txt": b"version 2\n",
         "empty/": b"", "added.txt": b"right only", "kind/child.txt": b"now a directory",
         "new-name.dat": left["old-name.dat"], "说明/本地.txt": left["说明/本地.txt"]}
with zipfile.ZipFile(root / "left.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in left.items():
        z.writestr(name, data)
    entry = zipfile.ZipInfo("link")
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    z.writestr(entry, "docs/common.txt")
with tarfile.open(root / "right.tar.gz", "w:gz") as t:
    for name, data in right.items():
        entry = tarfile.TarInfo(name)
        entry.type = tarfile.DIRTYPE if name.endswith("/") else tarfile.REGTYPE
        entry.size = len(data)
        t.addfile(entry, io.BytesIO(data))
folder = root / "right-folder"
folder.mkdir()
for name, data in right.items():
    path = folder / name
    if name.endswith("/"):
        path.mkdir(parents=True, exist_ok=True)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
(root / "damaged.zip").write_bytes(b"PK\x03\x04invalid")
# Canonical-equivalent parent spelling can be longer in UTF-8 than a child.
# Directory summaries must propagate by depth, never encoded byte length.
for name, entries in [("unicode-left.tar", {"outer/" + "e\u0301" * 10 + "/": b""}),
                      ("unicode-right.tar", {"outer/" + "é" * 10 + "/x": b"new"})]:
    with tarfile.open(root / name, "w") as t:
        for path, data in entries.items():
            entry = tarfile.TarInfo(path)
            entry.type = tarfile.DIRTYPE if path.endswith("/") else tarfile.REGTYPE
            entry.size = len(data)
            t.addfile(entry, io.BytesIO(data))

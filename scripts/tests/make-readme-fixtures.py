#!/usr/bin/env python3
"""Deterministic, project-local demonstration files for the public screenshots."""
import array
import importlib.util
import math
from pathlib import Path
import runpy
import sys
import wave
import zipfile

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
if root not in out.parents:
    raise SystemExit("README fixtures must remain inside this project")
out.mkdir(parents=True, exist_ok=True)
for side in ("Project Original", "Project Revised"):
    folder = out / side
    files = {
        "README.md": "# Coastal Studio\nA small local-first creative workspace.\n",
        "Sources/App.swift": "struct StudioApp { let version = 1 }\n",
        "Sources/Models/Project.swift": "struct Project { var title = \"Untitled\" }\n",
        "Sources/Views/Gallery.swift": "let columns = 3\nlet spacing = 16\n",
        "Resources/Colors.json": '{"accent":"ocean","canvas":"pearl"}\n',
        "Resources/Templates/Contact Sheet.md": "# Contact Sheet\nOriginal exposures\n",
        "Tests/ProjectTests.swift": "assert(project.title == \"Untitled\")\n",
        "docs/quick-start.md": "Choose a project, add photographs, and compare your edits.\n",
        "docs/shortcuts.md": "Command+N: New project\nCommand+F: Find\n",
        "Package.swift": "// Coastal Studio\n// macOS 14 and later\n",
    }
    if side.endswith("Revised"):
        files.update({
            "Sources/App.swift": "struct StudioApp { let version = 2 }\n",
            "Sources/Views/Gallery.swift": "let columns = 4\nlet spacing = 20\n",
            "Sources/Models/Collection.swift": "struct Collection { var images: [Image] = [] }\n",
            "Resources/Colors.json": '{"accent":"deep-ocean","canvas":"pearl"}\n',
            "docs/export.md": "Export a local contact sheet as a PDF.\n",
            "docs/quick-start.md": "Choose a project, add photographs, group a collection, and compare your edits.\n",
        })
        del files["Resources/Templates/Contact Sheet.md"]
    for name, value in files.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

shared = {
    "Coastal study.tiff": b"Synthetic photograph demonstration asset\n" * 80,
    "Studio guide.pdf": b"Synthetic guide demonstration asset\n" * 45,
    "Color palette.json": b'{"sea":"#22657a","sand":"#e5cba4"}\n' * 8,
    "Contact sheet.csv": b"frame,title,rating\n01,Coastal light,5\n" * 12,
}
for revised in (False, True):
    with zipfile.ZipFile(out / ("Collection Revised.zip" if revised else "Collection Original.zip"), "w", zipfile.ZIP_DEFLATED) as archive:
        for index, (name, data) in enumerate(shared.items()):
            parent = ["Portfolio/Seascapes", "Documents", "Design", "Exports"][index] if revised else ["Originals", "Notes", "Resources", "Review"][index]
            archive.writestr(parent + "/" + name, data)
            if index == 0 and not revised:
                archive.writestr("Favorites/" + name, data)
        archive.writestr("README.md", "Revised collection" if revised else "Original collection")

sys.argv = [str(root / "scripts/tests/make-office-demo.py"), str(out)]
office = runpy.run_path(str(root / "scripts/tests/make-office-demo.py"))
rows = [["ID", "Milestone", "Progress"], ["CD-101", "Native workspace", 100], ["CD-102", "Document comparison", 60],
        ["CD-103", "Cross-row matching", 45], ["CD-104", "Slide preview", 30], ["CD-105", "Light & dark themes", 80],
        ["CD-106", "Keyboard navigation", 75], ["CD-107", "Plugin catalog", 55], ["CD-108", "User guide", 20],
        ["CD-109", "Local recovery", 90], ["CD-110", "Release testing", 40]]
updated = [rows[0], rows[4], rows[1], ["CD-102", "Document comparison", 90], ["CD-105", "Light & dark themes", 100],
           ["CD-103", "Cross-row matching", 85], rows[6], ["CD-107", "Plugin catalog", 95], rows[9],
           ["CD-110", "Release testing", 80], ["CD-111", "Offline installer", 65]]
office["workbook"]("Milestones Original.xlsx", rows)
office["workbook"]("Milestones Revised.xlsx", updated)

spec = importlib.util.spec_from_file_location("readme_audio", root / "scripts/audio-research/check-matcher.py")
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)
audio.RATE = rate = 48000
source = audio.signal(918, seconds=30)
sections = [(1, 10, 1.5), (12, 22, 1.15), (25, 29, 0.9)]
for i in range(len(source)):
    time = i / rate
    gain = 0
    for index, (start, end, amplitude) in enumerate(sections):
        if start <= time < end:
            t = time - start
            phase = (t % (0.78 + index * 0.15)) / (0.78 + index * 0.15)
            pulse = math.sin(math.pi * phase / 0.8) ** 2 if phase < 0.8 else 0
            gain = amplitude * math.sin(math.pi * t / (end - start)) ** 0.35 * (0.08 + 0.92 * pulse)
            break
    source[i] *= gain
edited = source[12*rate:22*rate] + array.array("f", [0]) * int(0.8*rate) + source[rate:10*rate]
for name, values in [("Studio Original.wav", source), ("Studio Edited.wav", edited)]:
    samples = array.array("h", (round(max(-1, min(1, value)) * 32767) for value in values))
    if sys.byteorder != "little": samples.byteswap()
    with wave.open(str(out / name), "wb") as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(rate); output.writeframes(samples.tobytes())
print("Prepared synthetic README fixtures:", out)

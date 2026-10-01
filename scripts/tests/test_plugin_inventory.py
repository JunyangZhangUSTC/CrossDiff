#!/usr/bin/env python3
"""Exercise edition packaging and catalog integrity without building or accessing the network."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import plugin_inventory as inventory


class InventoryTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / ".build/tests/plugin-inventory"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
        self.catalog, self.packages = inventory.build_inventory(self.version)

    def run_inventory(self, *arguments):
        subprocess.run([sys.executable, "scripts/plugin_inventory.py", *map(str, arguments)],
                       cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_catalog_contains_only_official_packages_with_exact_hash_size_and_release_url(self):
        catalog = json.loads(self.catalog)
        self.assertEqual(catalog["releaseTag"], f"v{self.version}")
        self.assertEqual(catalog["formatVersion"], 1)
        self.assertEqual([p["id"] for p in catalog["plugins"]], ["org.crossdiff.archive", "org.crossdiff.pdf", "org.crossdiff.photography", "org.crossdiff.api", "org.crossdiff.audio"])
        self.assertEqual(len(self.packages), 6)
        self.assertTrue(any(name.startswith("CrossDiff-Example-JSON-") for name in self.packages))
        for plugin in catalog["plugins"]:
            contents = self.packages[plugin["asset"]]
            self.assertEqual(plugin["size"], len(contents))
            self.assertEqual(plugin["sha256"], hashlib.sha256(contents).hexdigest())
            self.assertEqual(plugin["url"], f"https://github.com/{inventory.REPOSITORY}/releases/download/v{self.version}/{plugin['asset']}")
            manifest = json.loads(contents)["manifest"]
            for field in ("id", "version", "name", "summary"):
                self.assertEqual(plugin[field], manifest[field])

    def test_full_to_base_rebuild_removes_optional_plugins_and_keeps_identical_offline_catalog(self):
        resources, release_dir = self.directory / "Resources", self.directory / "release"
        self.run_inventory("--bundle-resources", resources, "--edition", "full")
        self.assertEqual(len(list((resources / "Plugins").iterdir())), 5)
        (resources / "Plugins/stale.crossdiffplugin").write_text("previous build")
        self.run_inventory("--bundle-resources", resources, "--edition", "base")
        self.assertEqual([p.name for p in (resources / "Plugins").iterdir()], ["dev.crossdiff.archive.crossdiffplugin"])
        self.run_inventory("--output", release_dir)
        self.assertEqual((resources / "OfficialPlugins.json").read_bytes(), (release_dir / "plugins.json").read_bytes())
        for name, content in self.packages.items():
            self.assertEqual((release_dir / name).read_bytes(), content)
        inventory.validate_catalog((release_dir / "plugins.json").read_bytes(), self.packages, self.version)

    def test_standalone_official_packagers_match_release_payload_bytes(self):
        for label, script in (("Archive", "package-archive-plugin.py"), ("PDF", "package-pdf-plugin.py"), ("Photography", "package-photography-plugin.py"), ("API", "package-api-plugin.py"), ("Audio", "package-audio-plugin.py")):
            target = self.directory / (label + ".crossdiffplugin")
            subprocess.run([sys.executable, "scripts/" + script, "--output", str(target)], cwd=ROOT,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            expected = next(data for name, data in self.packages.items() if name.startswith(f"CrossDiff-Plugin-{label}-"))
            self.assertEqual(target.read_bytes(), expected)

    def test_manifest_identity_version_runtime_and_translation_are_validated(self):
        for field, value in (("id", "unexpected.plugin"), ("version", "../0.1.0"),
                             ("runtime", "trustedExecutable"), ("name", {"zhHans": "name"})):
            def read(path):
                data = (ROOT / path).read_bytes()
                if path.endswith("manifest.json"):
                    manifest = json.loads(data)
                    manifest[field] = value
                    return inventory.json_bytes(manifest)
                return data
            with self.subTest(field=field), self.assertRaises(ValueError):
                inventory.build_inventory(self.version, read)

    def test_catalog_or_package_mutations_are_rejected(self):
        catalog = json.loads(self.catalog)
        catalog["plugins"][0]["url"] = "https://example.com/plugin.crossdiffplugin"
        with self.assertRaises(ValueError):
            inventory.validate_catalog(inventory.json_bytes(catalog), self.packages, self.version)
        packages = dict(self.packages)
        first = next(iter(packages))
        packages[first] += b" "
        with self.assertRaises(ValueError):
            inventory.validate_catalog(self.catalog, packages, self.version)

    def test_external_output_and_symlinked_asset_are_rejected_before_writing(self):
        with self.assertRaises(ValueError):
            inventory.project_output(ROOT.parent / "outside-release")
        outside_name = self.directory / "existing"
        outside_name.write_text("keep")
        destination = self.directory / "release"
        destination.mkdir()
        (destination / "plugins.json").symlink_to(outside_name)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_inventory("--output", destination)
        self.assertEqual(outside_name.read_text(), "keep")

    def test_app_builder_rejects_bad_editions_or_external_destination_before_compiling(self):
        for arguments in (("--edition", "unknown"), ("--output", str(ROOT.parent / "CrossDiff.app"))):
            result = subprocess.run(["bash", "scripts/build-app.sh", *arguments], cwd=ROOT,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b"Building for", result.stdout)


if __name__ == "__main__":
    unittest.main()

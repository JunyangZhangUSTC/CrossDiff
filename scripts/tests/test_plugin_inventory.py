#!/usr/bin/env python3
"""Exercise edition packaging and catalog integrity without building or accessing the network."""
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile

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

    def write_app(self, edition, missing=None, changed=None):
        path = self.directory / (edition + ".zip")
        metadata = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        with zipfile.ZipFile(path, "w") as archive:
            prefix = "CrossDiff.app/Contents/"
            archive.writestr(prefix + "Info.plist", plistlib.dumps(metadata))
            for name in inventory.APP_EXECUTABLE_FILES:
                if name == missing:
                    continue
                mode, contents = stat.S_IFREG | 0o755, b"\xcf\xfa\xed\xfe" + bytes(28)
                if changed and name == changed[0]:
                    mode, contents = changed[1:]
                entry = zipfile.ZipInfo(prefix + name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, contents)
            for notice in inventory.APP_LICENSE_FILES:
                archive.writestr(prefix + "Resources/" + notice, "notice fixture")
            archive.writestr(prefix + "Resources/OfficialPlugins.json", self.catalog)
            for name, data in inventory.bundle_inventory(edition, self.packages).items():
                archive.writestr(prefix + "Resources/Plugins/" + name, data)
        return path, metadata

    def test_complete_base_and_full_archives_pass_executable_and_resource_validation(self):
        for edition in ("base", "full"):
            with self.subTest(edition=edition):
                path, metadata = self.write_app(edition)
                inventory.validate_app_archive(path, edition, self.catalog, self.packages, metadata)

    def test_each_required_executable_is_mandatory_in_both_editions(self):
        for edition in ("base", "full"):
            for name in inventory.APP_EXECUTABLE_FILES:
                with self.subTest(edition=edition, name=name):
                    path, metadata = self.write_app(edition, missing=name)
                    with self.assertRaisesRegex(ValueError, "Missing required application executable"):
                        inventory.validate_app_archive(path, edition, self.catalog, self.packages, metadata)

    def test_required_executables_reject_wrong_file_type_permissions_or_payload(self):
        header = b"\xcf\xfa\xed\xfe" + bytes(28)
        for mode, contents in ((stat.S_IFREG | 0o644, header), (stat.S_IFLNK | 0o777, header),
                               (stat.S_IFDIR | 0o755, header), (stat.S_IFREG | 0o755, b""),
                               (stat.S_IFREG | 0o755, header[:4]),
                               (stat.S_IFREG | 0o755, b"not a Mach-O executable" * 2)):
            for name in inventory.APP_EXECUTABLE_FILES:
                with self.subTest(name=name, mode=mode, size=len(contents)):
                    path, metadata = self.write_app("base", changed=(name, mode, contents))
                    with self.assertRaisesRegex(ValueError, "Application executable"):
                        inventory.validate_app_archive(path, "base", self.catalog, self.packages, metadata)

    def test_catalog_contains_only_official_packages_with_exact_hash_size_and_release_url(self):
        catalog = json.loads(self.catalog)
        self.assertEqual(catalog["releaseTag"], f"v{self.version}")
        self.assertEqual(catalog["formatVersion"], 1)
        self.assertEqual([p["id"] for p in catalog["plugins"]], ["org.crossdiff.archive", "org.crossdiff.git", "org.crossdiff.pdf", "org.crossdiff.photography", "org.crossdiff.api", "org.crossdiff.audio", "org.crossdiff.office", "org.crossdiff.video"])
        self.assertEqual(len(self.packages), 9)
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
        self.assertEqual(len(list((resources / "Plugins").iterdir())), 8)
        (resources / "Plugins/stale.crossdiffplugin").write_text("previous build")
        self.run_inventory("--bundle-resources", resources, "--edition", "base")
        self.assertEqual(sorted(p.name for p in (resources / "Plugins").iterdir()), ["dev.crossdiff.archive.crossdiffplugin", "dev.crossdiff.git.crossdiffplugin"])
        self.run_inventory("--output", release_dir)
        self.assertEqual((resources / "OfficialPlugins.json").read_bytes(), (release_dir / "plugins.json").read_bytes())
        for name, content in self.packages.items():
            self.assertEqual((release_dir / name).read_bytes(), content)
        inventory.validate_catalog((release_dir / "plugins.json").read_bytes(), self.packages, self.version)

    def test_standalone_official_packagers_match_release_payload_bytes(self):
        for label, script in (("Archive", "package-archive-plugin.py"), ("Git", "package-git-plugin.py"), ("PDF", "package-pdf-plugin.py"), ("Photography", "package-photography-plugin.py"), ("API", "package-api-plugin.py"), ("Audio", "package-audio-plugin.py"), ("Office", "package-office-plugin.py"), ("Video", "package-video-plugin.py")):
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

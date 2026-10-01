#!/usr/bin/env python3
"""Offline release safety checks. All fixtures remain inside the repository."""

from copy import deepcopy
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("github_release", ROOT / "scripts/publish-github-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
COMMIT = "a" * 40
TAG = "v0.4.0"


class FakeGitHub:
    """In-memory API: tests must never authenticate or contact GitHub."""

    repository = "owner/CrossDiff"

    def __init__(self, existing=None):
        self.release = deepcopy(existing)
        self.calls = []
        self.contents = {}
        self.next_id = 1
        self.assert_remote_tag = Mock()
        self.upload_count = 0
        self.download_count = 0

    def find_release(self, tag):
        return deepcopy(self.release)

    def api(self, method, path, payload=None):
        self.calls.append((method, path))
        if method == "POST":
            self.release = dict(payload, id=1, assets=[], published_at=None, immutable=False,
                                upload_url="https://uploads.github.com/repos/owner/CrossDiff/releases/1/assets{?name,label}",
                                html_url="https://github.com/owner/CrossDiff/releases/tag/v0.4.0")
        elif method == "PATCH":
            self.release.update(payload)
        elif method == "DELETE":
            asset_id = int(path.rsplit("/", 1)[1])
            self.release["assets"] = [asset for asset in self.release["assets"] if asset["id"] != asset_id]
            del self.contents[asset_id]
            return None
        return deepcopy(self.release)

    def upload(self, current, path):
        asset = {"id": self.next_id, "name": path.name, "state": "uploaded"}
        self.next_id += 1
        self.contents[asset["id"]] = path.read_bytes()
        self.release["assets"].append(asset)
        self.upload_count += 1
        return asset

    def download(self, asset_id, path):
        path.write_bytes(self.contents[asset_id])
        self.download_count += 1


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / ".build" / "tests" / "github-release"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "dist"
        self.directory.mkdir()
        self.app = "CrossDiff-0.4.0-macOS-arm64.zip"
        self.source = "CrossDiff-0.4.0-source.tar.gz"
        (self.directory / self.app).write_bytes(b"app archive fixture")
        (self.directory / self.source).write_bytes(b"source archive fixture")
        info = ("CrossDiff release bundle\nVersion: 0.4.0\nBuild: 10\n"
                f"Source commit: {COMMIT}\nArchitecture: arm64\nLicense: AGPL-3.0-only\n"
                "Signing: ad-hoc\nNotarized: no\n"
                f"Application archive: {self.app}\nSource archive: {self.source}\n")
        (self.directory / "BUILD-INFO.txt").write_text(info, encoding="utf-8")
        self.write_manifest()
        self.git = patch.object(release, "git", side_effect=self.git_value).start()
        self.addCleanup(patch.stopall)

    def git_value(self, root, *arguments):
        if arguments[0] == "rev-parse":
            return COMMIT
        if arguments[-1] == "HEAD:Resources/Info.plist":
            return plistlib.dumps({"CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "10"}).decode()
        if arguments[-1] == "HEAD:docs/releases/0.4.0.md":
            return "预览版本 / Preview release."
        raise AssertionError(arguments)

    def write_manifest(self):
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{release.checksum(self.directory / name)}  {name}\n"
            for name in (self.app, self.source, "BUILD-INFO.txt")), encoding="utf-8")

    def package(self):
        return release.validate_package(self.root, TAG, self.directory)

    def test_creates_draft_with_four_verified_downloads_and_can_retry(self):
        package = self.package()
        github = FakeGitHub()
        url = release.publish(github, self.root, package)
        self.assertEqual(url, "https://github.com/owner/CrossDiff/releases/tag/v0.4.0")
        self.assertTrue(github.release["draft"])
        self.assertTrue(github.release["prerelease"])
        self.assertEqual(github.release["target_commitish"], COMMIT)
        self.assertEqual(github.release["make_latest"], "false")
        self.assertEqual((github.upload_count, github.download_count), (4, 4))
        release.publish(github, self.root, package)
        self.assertEqual((github.upload_count, github.download_count), (8, 8))
        self.assertEqual(len(github.release["assets"]), 4)
        self.assertEqual(sum(method == "POST" for method, _ in github.calls), 1)

    def test_published_and_immutable_releases_are_never_modified(self):
        for draft, immutable, published_at in [(False, False, "2026-10-01"), (True, True, None), (True, False, "2026-10-01")]:
            with self.subTest(draft=draft, immutable=immutable):
                github = FakeGitHub({"draft": draft, "immutable": immutable, "published_at": published_at,
                                     "target_commitish": COMMIT, "tag_name": TAG})
                with self.assertRaisesRegex(release.ReleaseError, "published or immutable"):
                    release.publish(github, self.root, self.package())
                self.assertEqual(github.calls, [])
                self.assertEqual(github.upload_count, 0)

    def test_existing_draft_with_different_sha_is_never_modified(self):
        github = FakeGitHub({"draft": True, "published_at": None, "target_commitish": "b" * 40, "tag_name": TAG})
        with self.assertRaisesRegex(release.ReleaseError, "another source commit"):
            release.publish(github, self.root, self.package())
        self.assertEqual(github.calls, [])

    def test_bad_checksums_prevent_api_client_creation(self):
        (self.directory / self.app).write_bytes(b"corrupted")
        with patch("sys.argv", ["publish", "--tag", TAG, "--directory", str(self.directory)]), \
                patch.object(release, "__file__", str(self.root / "scripts/publish-github-release.py")), \
                patch.object(release, "GitHub") as client, patch("sys.stderr"):
            self.assertEqual(release.main(), 1)
            client.assert_not_called()

    def test_build_info_must_match_commit_even_if_checksum_is_valid(self):
        path = self.directory / "BUILD-INFO.txt"
        path.write_text(path.read_text().replace(COMMIT, "b" * 40))
        self.write_manifest()
        with self.assertRaisesRegex(release.ReleaseError, "BUILD-INFO.txt does not match"):
            self.package()

    def test_extra_files_and_duplicate_manifest_entries_are_rejected(self):
        extra = self.directory / "unexpected.txt"
        extra.write_text("not a release asset")
        with self.assertRaisesRegex(release.ReleaseError, "exactly the four"):
            self.package()
        extra.unlink()
        manifest = self.directory / "SHA256SUMS"
        manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(release.ReleaseError, "duplicate SHA256SUMS"):
            self.package()

    def test_404_looks_for_drafts_but_authentication_failure_stops(self):
        github = release.GitHub("owner/CrossDiff", "test-value")
        draft = {"tag_name": TAG, "draft": True}
        github.api = Mock(side_effect=[release.APIError(404), [draft]])
        self.assertEqual(github.find_release(TAG), draft)
        for code in (401, 403, 500):
            github.api = Mock(side_effect=release.APIError(code))
            with self.assertRaises(release.APIError):
                github.find_release(TAG)
            self.assertEqual(github.api.call_count, 1)

    def test_remote_tag_handles_annotated_and_lightweight_and_rejects_movement(self):
        github = release.GitHub("owner/CrossDiff", "test-value")
        github.api = Mock(return_value={"object": {"type": "commit", "sha": COMMIT}})
        github.assert_remote_tag(TAG, COMMIT)
        github.api = Mock(side_effect=[{"object": {"type": "tag", "sha": "c" * 40}},
                                       {"object": {"type": "commit", "sha": COMMIT}}])
        github.assert_remote_tag(TAG, COMMIT)
        github.api = Mock(return_value={"object": {"type": "commit", "sha": "b" * 40}})
        with self.assertRaisesRegex(release.ReleaseError, "remote tag no longer"):
            github.assert_remote_tag(TAG, COMMIT)

    def test_tag_format_version_and_local_commit_must_match(self):
        for tag in ("main", "v0.4.0/unsafe", "v0.4.0;echo", "v00.4.0", "v0.5.0"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.validate_package(self.root, tag, self.directory)
        self.git.side_effect = [COMMIT, "b" * 40]
        with self.assertRaisesRegex(release.ReleaseError, "local tag must point"):
            self.package()

    def test_asset_redirect_strips_credentials_and_rejects_other_hosts(self):
        handler = release.AssetRedirects()
        request = urllib.request.Request("https://api.github.com/repos/owner/CrossDiff/releases/assets/1",
                                         headers={"Authorization": "Bearer test-value"})
        redirected = handler.redirect_request(request, None, 302, "Found", {},
                                               "https://release-assets.githubusercontent.com/asset")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(release.ReleaseError):
            handler.redirect_request(request, None, 302, "Found", {}, "https://example.com/asset")
        github = release.GitHub("owner/CrossDiff", "test-value")
        with patch.object(github, "open") as opened:
            with self.assertRaisesRegex(release.ReleaseError, "upload URL"):
                github.upload({"id": 1, "upload_url": "https://example.com/upload"}, self.directory / self.app)
            opened.assert_not_called()

    def test_remote_tag_movement_prevents_creation(self):
        github = FakeGitHub()
        github.assert_remote_tag.side_effect = release.ReleaseError("tag moved")
        with self.assertRaisesRegex(release.ReleaseError, "tag moved"):
            release.publish(github, self.root, self.package())
        self.assertEqual(github.calls, [])
        self.assertEqual(github.upload_count, 0)

    def test_download_corruption_never_reports_success(self):
        github = FakeGitHub()
        github.download = lambda asset_id, path: path.write_bytes(b"incorrect bytes")
        with self.assertRaisesRegex(release.ReleaseError, "Downloaded asset checksum mismatch"):
            release.publish(github, self.root, self.package())
        self.assertTrue(github.release["draft"])


if __name__ == "__main__":
    unittest.main()

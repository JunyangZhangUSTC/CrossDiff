#!/usr/bin/env python3
"""Publish verified stable releases, honoring committed historical release intent."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plugin_inventory


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, status: int):
        self.status = status
        super().__init__(f"GitHub API returned HTTP {status}; no credentials or response body are logged.")


class AssetRedirects(urllib.request.HTTPRedirectHandler):
    """Only asset downloads may redirect, without forwarding credentials."""

    def redirect_request(self, request, response, code, message, headers, new_url):
        destination = urllib.parse.urlsplit(new_url)
        if (request.get_method() != "GET" or destination.scheme != "https"
                or destination.hostname not in {"release-assets.githubusercontent.com", "objects.githubusercontent.com"}
                or destination.username or destination.password or destination.port not in (None, 443)):
            raise ReleaseError("Refusing an unexpected GitHub redirect.")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", repository) or repository.split("/")[1] in {".", ".."}:
            raise ReleaseError("GITHUB_REPOSITORY must be an owner/repository name.")
        if not token:
            raise ReleaseError("GH_TOKEN is required; use the workflow's GITHUB_TOKEN.")
        self.repository = repository
        self.token = token
        self.base = f"https://api.github.com/repos/{repository}"
        self.opener = urllib.request.build_opener(AssetRedirects())

    def open(self, method: str, url: str, data=None, accept="application/vnd.github+json", content_type=None):
        destination = urllib.parse.urlsplit(url)
        if (destination.scheme != "https" or destination.hostname not in {"api.github.com", "uploads.github.com"}
                or destination.username or destination.password or destination.port not in (None, 443)):
            raise ReleaseError("Refusing an unexpected API or upload host.")
        headers = {"Authorization": f"Bearer {self.token}", "Accept": accept,
                   "User-Agent": "CrossDiff-release", "X-GitHub-Api-Version": "2022-11-28"}
        if content_type:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            return self.opener.open(request, timeout=120)
        except urllib.error.HTTPError as error:
            raise APIError(error.code) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise ReleaseError("GitHub request failed or timed out; retry the workflow after checking connectivity.") from None

    def api(self, method: str, path: str, payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        with self.open(method, self.base + path, data, content_type="application/json") as response:
            body = response.read()
        return json.loads(body) if body else None

    def find_release(self, tag: str):
        try:
            return self.api("GET", f"/releases/tags/{tag}")
        except APIError as error:
            if error.status != 404:
                raise
        # The tag endpoint only promises published releases. Include drafts for retries.
        page = 1
        while True:
            releases = self.api("GET", f"/releases?per_page=100&page={page}")
            matches = [release for release in releases if release["tag_name"] == tag]
            if len(matches) > 1:
                raise ReleaseError("More than one release uses this tag; resolve the duplicate drafts first.")
            if matches:
                return matches[0]
            if len(releases) < 100:
                return None
            page += 1

    def assert_remote_tag(self, tag: str, commit: str):
        obj = self.api("GET", f"/git/ref/tags/{tag}")["object"]
        seen = set()
        while obj["type"] == "tag":
            sha = obj["sha"]
            if sha in seen or len(seen) >= 20 or not re.fullmatch(r"[a-f0-9]{40}", sha):
                raise ReleaseError("Invalid or excessively nested annotated tag.")
            seen.add(sha)
            obj = self.api("GET", f"/git/tags/{sha}")["object"]
        if obj["type"] != "commit" or obj["sha"] != commit:
            raise ReleaseError("The remote tag no longer points to the packaged source commit.")

    def upload(self, release: dict, path: Path):
        expected = f"https://uploads.github.com/repos/{self.repository}/releases/{release['id']}/assets"
        if release["upload_url"].split("{", 1)[0] != expected:
            raise ReleaseError("Unexpected release upload URL.")
        url = expected + "?" + urllib.parse.urlencode({"name": path.name})
        mime = "application/zip" if path.suffix == ".zip" else "application/gzip" if path.suffix == ".gz" else "application/json" if path.suffix in {".json", ".crossdiffplugin"} else "text/plain"
        with self.open("POST", url, path.read_bytes(), content_type=mime) as response:
            return json.loads(response.read())

    def download(self, asset_id: int, path: Path):
        with self.open("GET", self.base + f"/releases/assets/{asset_id}", accept="application/octet-stream") as response:
            with path.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)


def git(root: Path, *arguments: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.PIPE).decode("utf-8").strip()
    except subprocess.CalledProcessError:
        raise ReleaseError("Could not resolve the expected Git commit, tag, or committed release metadata.") from None


def git_bytes(root: Path, *arguments: str) -> bytes:
    try:
        return subprocess.check_output(["git", "-C", str(root), *arguments], stderr=subprocess.PIPE)
    except subprocess.CalledProcessError:
        raise ReleaseError("Could not read committed release source.") from None


def release_intent(root: Path, commit: str, version: str) -> dict:
    """New versions default to stable publication; fixed-commit overrides remain authoritative."""
    path = f"docs/releases/{version}.json"
    entry = git(root, "ls-tree", "-z", commit, "--", path)
    defaults = {"formatVersion": 1, "version": version, "publish": True, "prerelease": False}
    if not entry:
        return defaults
    if not re.fullmatch(r"100644 blob [a-f0-9]{40}\t" + re.escape(path) + r"\x00", entry):
        raise ReleaseError("Release intent must be a regular committed JSON file.")

    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ReleaseError("Duplicate key in committed release intent.")
            result[key] = value
        return result

    try:
        intent = json.loads(git_bytes(root, "show", f"{commit}:{path}"), object_pairs_hook=unique_keys)
    except (ValueError, UnicodeError):
        raise ReleaseError("Invalid committed release intent JSON.") from None
    if (not isinstance(intent, dict) or set(intent) != set(defaults)
            or type(intent["formatVersion"]) is not int or intent["formatVersion"] != 1
            or intent["version"] != version
            or type(intent["publish"]) is not bool or type(intent["prerelease"]) is not bool):
        raise ReleaseError("Release intent must have exact keys, schema 1, matching version and boolean flags.")
    return intent


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_package(root: Path, tag: str, directory: Path) -> dict:
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise ReleaseError("Expected a release tag in vX.Y.Z format.")
    root, directory = root.resolve(), directory.resolve()
    if not directory.is_relative_to(root) or not directory.is_dir():
        raise ReleaseError("Release artifacts must be in a directory inside this checkout.")
    commit = git(root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[a-f0-9]{40}", commit) or git(root, "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}") != commit:
        raise ReleaseError("The local tag must point to HEAD.")
    metadata = plistlib.loads(git(root, "show", f"{commit}:Resources/Info.plist").encode("utf-8"))
    version, build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
    if tag != f"v{version}" or not re.fullmatch(r"[0-9]+", build):
        raise ReleaseError("The tag and committed app version must agree.")
    base = f"CrossDiff-{version}-base-macOS-arm64.zip"
    full = f"CrossDiff-{version}-full-macOS-arm64.zip"
    committed_read = lambda path: git_bytes(root, "show", f"{commit}:{path}")
    catalog, plugins = plugin_inventory.build_inventory(version, committed_read)
    source = f"CrossDiff-{version}-source.tar.gz"
    names = [base, full, source, *plugins, "plugins.json", "BUILD-INFO.txt", "SHA256SUMS"]
    if {path.name for path in directory.iterdir()} != set(names):
        raise ReleaseError("The release directory must contain exactly the expected edition, plugin, catalog and source artifacts.")
    if any((directory / name).is_symlink() or not (directory / name).is_file() for name in names):
        raise ReleaseError("Release artifacts must be regular files, not symlinks.")
    manifest = {}
    for line in (directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([a-f0-9]{64})  ([A-Za-z0-9._-]+)", line)
        if not match or match[2] in manifest:
            raise ReleaseError("Invalid or duplicate SHA256SUMS entry.")
        manifest[match[2]] = match[1]
    if set(manifest) != set(names[:-1]):
        raise ReleaseError("SHA256SUMS must cover every release artifact except itself.")
    for name, expected in manifest.items():
        if checksum(directory / name) != expected:
            raise ReleaseError(f"Checksum mismatch: {name}.")
    lines = (directory / "BUILD-INFO.txt").read_text(encoding="utf-8").splitlines()
    expected_info = {"Version": version, "Build": build, "Source commit": commit,
                     "Architecture": "arm64", "License": "AGPL-3.0-only", "Signing": "ad-hoc",
                     "Notarized": "no", "Base application archive": base, "Full application archive": full,
                     "Plugin catalog": "plugins.json", "Source archive": source}
    if not lines or lines[0] != "CrossDiff release bundle" or len(lines[1:]) != len(expected_info):
        raise ReleaseError("Invalid BUILD-INFO.txt.")
    if any(": " not in line for line in lines[1:]) or dict(line.split(": ", 1) for line in lines[1:]) != expected_info:
        raise ReleaseError("BUILD-INFO.txt does not match the committed version, source, architecture, or signing status.")
    try:
        plugin_inventory.validate_catalog((directory / "plugins.json").read_bytes(),
                                          {name: (directory / name).read_bytes() for name in plugins}, version, committed_read)
        for edition, name in (("base", base), ("full", full)):
            plugin_inventory.validate_app_archive(directory / name, edition, catalog, plugins, metadata)
    except (ValueError, KeyError, zipfile.BadZipFile) as error:
        raise ReleaseError(f"Release inventory validation failed: {error}") from None
    notes = git(root, "show", f"{commit}:docs/releases/{version}.md")
    if not notes:
        raise ReleaseError("Committed release notes are empty.")
    return {"tag": tag, "version": version, "commit": commit, "directory": directory,
            "names": names, "hashes": {name: checksum(directory / name) for name in names},
            "intent": release_intent(root, commit, version),
            "body": notes + f"\n\nSource commit / 源码提交：`{commit}`\n\n<!-- crossdiff-source-commit: {commit} -->\n"}


def assert_draft(release: dict, package: dict):
    if release.get("draft") is not True or release.get("published_at") is not None or release.get("immutable") is True:
        raise ReleaseError("This release is already published or immutable; it will not be changed.")
    if release.get("tag_name") != package["tag"] or release.get("target_commitish") != package["commit"]:
        raise ReleaseError("The existing draft belongs to another source commit; it will not be changed.")


def assert_draft_assets(release: dict, package: dict):
    names = [asset["name"] for asset in release["assets"]]
    if any(name not in package["names"] for name in names):
        raise ReleaseError("The draft contains unexpected assets; it will not be overwritten.")
    if len(names) != len(set(names)):
        raise ReleaseError("The draft contains duplicate assets.")
    if any(asset["state"] not in {"uploaded", "starter"} for asset in release["assets"]):
        raise ReleaseError("Unexpected asset state; refusing to overwrite it.")


def assert_release_metadata(release: dict, package: dict):
    expected = {"tag_name": package["tag"], "target_commitish": package["commit"],
                "name": f"CrossDiff {package['tag']}", "body": package["body"],
                "prerelease": package["intent"]["prerelease"]}
    if any(release.get(key) != value for key, value in expected.items()):
        raise ReleaseError("Release metadata does not match the committed source and intent.")
    expected_url = f"https://github.com/{plugin_inventory.REPOSITORY}/releases/tag/{package['tag']}"
    # Drafts can use a temporary untagged URL, but must remain in this repository.
    if not isinstance(release.get("html_url"), str) or not release["html_url"].startswith(
            f"https://github.com/{plugin_inventory.REPOSITORY}/releases/"):
        raise ReleaseError("Unexpected release page URL.")
    if release.get("draft") is False and release["html_url"] != expected_url:
        raise ReleaseError("Unexpected published release page URL.")


def assert_complete_assets(release: dict, package: dict):
    assets = release["assets"]
    if (len(assets) != len(package["names"])
            or {asset["name"] for asset in assets} != set(package["names"])
            or any(asset.get("state") != "uploaded" for asset in assets)
            or any(type(asset.get("id")) is not int or asset["id"] <= 0 for asset in assets)
            or len({asset["id"] for asset in assets}) != len(assets)):
        raise ReleaseError("The release does not contain exactly the expected uploaded assets.")


def asset_snapshot(release: dict) -> list:
    return sorted((asset["id"], asset["name"], asset["state"], asset.get("size"),
                   asset.get("updated_at"), asset.get("digest")) for asset in release["assets"])


def verify_downloads(github: GitHub, root: Path, package: dict, release: dict):
    assert_release_metadata(release, package)
    assert_complete_assets(release, package)
    verification = root / ".build" / "release-verification"
    verification.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="github-", dir=verification) as temporary:
        for asset in release["assets"]:
            path = Path(temporary) / asset["name"]
            github.download(asset["id"], path)
            if checksum(path) != package["hashes"][asset["name"]]:
                raise ReleaseError(f"Downloaded asset checksum mismatch: {asset['name']}.")
    github.assert_remote_tag(package["tag"], package["commit"])
    current = github.api("GET", f"/releases/{release['id']}")
    assert_release_metadata(current, package)
    assert_complete_assets(current, package)
    if (asset_snapshot(current) != asset_snapshot(release)
            or current.get("draft") != release.get("draft")
            or current.get("published_at") != release.get("published_at")):
        raise ReleaseError("Release or assets changed while downloads were being verified.")
    return current


def publish(github: GitHub, root: Path, package: dict) -> dict:
    if github.repository != plugin_inventory.REPOSITORY:
        raise ReleaseError("The upload repository must match the official plugin catalog repository.")

    def unchanged(name):
        path = package["directory"] / name
        if path.is_symlink() or not path.is_file() or checksum(path) != package["hashes"][name]:
            raise ReleaseError(f"Artifact changed during publication: {name}.")
        return path

    for name in package["names"]:
        unchanged(name)
    github.assert_remote_tag(package["tag"], package["commit"])
    release = github.find_release(package["tag"])
    if release is not None and release.get("draft") is False:
        if not release.get("published_at"):
            raise ReleaseError("Published release has no publication timestamp; it will not be changed.")
        # A retry after successful publication is strictly read-only, including immutable releases.
        release = verify_downloads(github, root, package, release)
        return {"url": release["html_url"], "published": True, "prerelease": release["prerelease"]}
    values = {"tag_name": package["tag"], "target_commitish": package["commit"],
              "name": f"CrossDiff {package['tag']}", "body": package["body"],
              "draft": True, "prerelease": package["intent"]["prerelease"], "make_latest": "false"}
    if release is None:
        release = github.api("POST", "/releases", values)
    else:
        assert_draft(release, package)
        assert_draft_assets(release, package)
        release = github.api("PATCH", f"/releases/{release['id']}", values)
    assert_draft(release, package)
    assert_draft_assets(release, package)
    release_id = release["id"]

    def guarded_release():
        github.assert_remote_tag(package["tag"], package["commit"])
        current = github.api("GET", f"/releases/{release_id}")
        assert_draft(current, package)
        assert_draft_assets(current, package)
        assert_release_metadata(current, package)
        return current

    for name in package["names"]:
        path = unchanged(name)
        release = guarded_release()
        matches = [asset for asset in release["assets"] if asset["name"] == name]
        if matches:
            github.api("DELETE", f"/releases/assets/{matches[0]['id']}")
            release = guarded_release()
        path = unchanged(name)
        uploaded = github.upload(release, path)
        if uploaded.get("name") != name or uploaded.get("state") != "uploaded":
            raise ReleaseError("GitHub did not confirm a complete asset upload.")

    release = verify_downloads(github, root, package, guarded_release())
    assert_draft(release, package)
    if package["intent"]["publish"]:
        # The only publication mutation comes after every uploaded byte has been read back.
        github.assert_remote_tag(package["tag"], package["commit"])
        # Let GitHub consider semantic version and creation date for stable releases,
        # instead of forcing a backfilled older version to replace Latest.
        published = github.api("PATCH", f"/releases/{release_id}",
                               {"draft": False, "prerelease": package["intent"]["prerelease"],
                                "make_latest": "false" if package["intent"]["prerelease"] else "legacy"})
        assert_release_metadata(published, package)
        assert_complete_assets(published, package)
        if (published.get("draft") is not False or not published.get("published_at")
                or asset_snapshot(published) != asset_snapshot(release)):
            raise ReleaseError("GitHub did not confirm the verified release publication.")
        release = published
    return {"url": release["html_url"], "published": release["draft"] is False,
            "prerelease": release["prerelease"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        # Verify all local inputs before constructing an authenticated API client.
        package = validate_package(root, arguments.tag, arguments.directory)
        github = GitHub(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GH_TOKEN", ""))
        result = publish(github, root, package)
        url = result["url"]
        visibility = "Published" if result["published"] else "Draft (not published)"
        kind = "prerelease" if result["prerelease"] else "release"
        print(f"Verified {visibility.lower()} {kind}: {url}")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as output:
                output.write(f"### CrossDiff {package['tag']}\n\n[Open release]({url})\n\n"
                             f"Source: `{package['commit']}`. All {len(package['names'])} release assets were downloaded and SHA-256 verified.\n\n"
                             f"{visibility} {kind}; Apple silicon, ad-hoc signed, not notarized.\n")
        return 0
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"Release upload stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/bin/bash
# Prepare local release files from an exact, clean Git commit. Never uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: bash scripts/package-release.sh

Requires a clean, committed worktree. Builds and audits the current commit,
then writes the macOS app ZIP, matching source archive, SHA256SUMS, and
BUILD-INFO.txt under dist/releases/<version>-<commit>/.

The app is ad-hoc signed, not notarized. Nothing is installed or uploaded.
HELP
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf 'Unexpected arguments. Use --help for usage.\n' >&2
  exit 2
fi

fail() { printf 'Release packaging stopped: %s\n' "$*" >&2; exit 1; }
require_clean() {
  [[ -z "$(git status --porcelain --untracked-files=all)" ]] || \
    fail 'Commit or remove unrelated changes first; tracked and untracked worktree files must be clean.'
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail 'This must be run from the Git repository.'
require_clean
python3 - <<'CHECK_INDEX'
import subprocess, sys
entries = subprocess.check_output(['git', 'ls-files', '-v', '-z']).split(b'\0')
if any(entry and (entry[:1].islower() or entry[:1] == b'S') for entry in entries):
    sys.exit('Release packaging stopped: remove assume-unchanged/skip-worktree flags before packaging.')
CHECK_INDEX
release_commit="$(git rev-parse --verify HEAD)"
release_short_commit="$(git rev-parse --short=12 "$release_commit")"
# An explicit byte comparison also rejects local version overrides hidden by index flags.
git show "$release_commit:Resources/Info.plist" | cmp -s - Resources/Info.plist || \
  fail 'Resources/Info.plist differs from the selected commit.'
release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
release_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || fail 'Expected a safe semantic version in Info.plist.'
[[ "$release_build" =~ ^[0-9]+$ ]] || fail 'Expected a numeric CFBundleVersion.'
release_parent="$PWD/dist/releases"
release_destination="$release_parent/$release_version-$release_short_commit"
[[ ! -e "$release_destination" ]] || fail 'Output for this version and commit already exists; retain it or move it before running again.'

# Fail before a lengthy build if repository content or history is unsuitable.
python3 scripts/audit-publication.py --history
bash scripts/build-app.sh
release_app="$PWD/dist/CrossDiff.app"
cmp -s Resources/Info.plist "$release_app/Contents/Info.plist" || fail 'Built app metadata does not match the commit.'
for release_notice in LICENSE NOTICE; do
  cmp -s "$release_notice" "$release_app/Contents/Resources/$release_notice" || \
    fail "The app is missing the current $release_notice."
done
codesign --verify --deep --strict "$release_app"
python3 scripts/audit-publication.py --history --app "$release_app"
require_clean
[[ "$(git rev-parse HEAD)" == "$release_commit" ]] || fail 'HEAD changed during the build; retry from one fixed commit.'

release_architecture="$(/usr/bin/lipo -archs "$release_app/Contents/MacOS/CrossDiff" | tr ' ' '-')"
[[ "$release_architecture" =~ ^(arm64|x86_64)(-(arm64|x86_64))?$ ]] || fail 'Unexpected app architecture.'
mkdir -p "$release_parent"
release_stage="$(mktemp -d "$release_parent/.package.XXXXXX")"
trap 'if [[ -n "${release_stage:-}" && -d "$release_stage" ]]; then rm -rf "$release_stage"; fi' EXIT
release_app_name="CrossDiff-$release_version-macOS-$release_architecture.zip"
release_source_name="CrossDiff-$release_version-source.tar.gz"

# Omit resource forks, extended attributes, quarantine metadata and personal ACLs.
/usr/bin/ditto --norsrc --noextattr --noacl --noqtn --nopersistRootless \
  -c -k --keepParent "$release_app" "$release_stage/$release_app_name"
# ditto's Unix ZIP extra field still contains local uid/gid even with --noextattr.
# Strip ZIP extras while preserving file modes and symlink payloads.
python3 - "$release_stage/$release_app_name" <<'STRIP_ZIP_METADATA'
import os, sys, zipfile
archive_path = sys.argv[1]
clean_path = archive_path + '.clean'
with zipfile.ZipFile(archive_path) as source, zipfile.ZipFile(clean_path, 'w') as target:
    for entry in source.infolist():
        contents = source.read(entry)
        entry.extra = b''
        entry.comment = b''
        target.writestr(entry, contents)
os.replace(clean_path, archive_path)
STRIP_ZIP_METADATA
# git archive includes tracked files from this commit, never the worktree or .git.
git archive --format=tar --prefix="CrossDiff-$release_version/" "$release_commit" | \
  gzip -n > "$release_stage/$release_source_name"
cat > "$release_stage/BUILD-INFO.txt" <<INFO
CrossDiff release bundle
Version: $release_version
Build: $release_build
Source commit: $release_commit
Architecture: $release_architecture
License: AGPL-3.0-only
Signing: ad-hoc
Notarized: no
Application archive: $release_app_name
Source archive: $release_source_name
INFO

# Inspect archive names before producing checksums; do not extract into user locations.
python3 - "$release_stage/$release_app_name" "$release_stage/$release_source_name" "$release_version" <<'PY'
import sys, tarfile, zipfile
from pathlib import PurePosixPath
app_archive, source_archive, version = sys.argv[1:]
with zipfile.ZipFile(app_archive) as archive:
    names = archive.namelist()
    assert names and all(name.startswith('CrossDiff.app/') for name in names), 'Unexpected app archive root'
    assert not any(entry.extra or entry.comment for entry in archive.infolist()), 'Unexpected ZIP metadata'
    assert not any('__MACOSX' in PurePosixPath(name).parts or PurePosixPath(name).name.startswith('._') for name in names), 'Resource metadata in app archive'
    assert not any('..' in PurePosixPath(name).parts for name in names), 'Unsafe app archive entry'
    for notice in ('LICENSE', 'NOTICE'):
        assert f'CrossDiff.app/Contents/Resources/{notice}' in names, f'Missing {notice}'
with tarfile.open(source_archive, 'r:gz') as archive:
    entries = archive.getmembers()
    assert entries and all(entry.name == f'CrossDiff-{version}' or entry.name.startswith(f'CrossDiff-{version}/') for entry in entries), 'Unexpected source archive root'
    assert not any('..' in PurePosixPath(entry.name).parts or '.git' in PurePosixPath(entry.name).parts for entry in entries), 'Unsafe source archive entry'
    local_tools = {'.agents', '.codex', '.claude', '.cursor', '.continue', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'THIRD_PARTY_NOTICES.md'}
    assert not any(len(PurePosixPath(entry.name).parts) > 1 and
                   (PurePosixPath(entry.name).parts[1] in local_tools or
                    PurePosixPath(entry.name).parts[1].startswith('.aider'))
                   for entry in entries), 'Local development tools in source archive'
    for notice in ('LICENSE', 'NOTICE'):
        assert archive.getmember(f'CrossDiff-{version}/{notice}').isfile(), f'Missing source {notice}'
PY
(
  cd "$release_stage"
  shasum -a 256 "$release_app_name" "$release_source_name" BUILD-INFO.txt > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
# Verify that the actual ZIP still expands into a valid signed bundle.
mkdir "$release_stage/verification"
/usr/bin/ditto -x -k "$release_stage/$release_app_name" "$release_stage/verification"
codesign --verify --deep --strict "$release_stage/verification/CrossDiff.app"
rm -rf "$release_stage/verification"
require_clean
[[ "$(git rev-parse HEAD)" == "$release_commit" ]] || fail 'HEAD changed during packaging; retry from one fixed commit.'
mv "$release_stage" "$release_destination"
release_stage=''
printf 'Prepared local release files: %s\n' "$release_destination"
printf 'Source commit: %s\nAd-hoc signed; not notarized. Nothing was uploaded.\n' "$release_commit"

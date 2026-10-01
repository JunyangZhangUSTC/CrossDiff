#!/bin/bash
# Prepare local release files from an exact, clean Git commit. Never uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/project-env.sh

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: bash scripts/package-release.sh

Requires a clean, committed worktree. Builds and audits the current commit,
then writes Base and Full macOS app ZIPs, official plugin packages, the JSON
example, plugins.json, matching source, SHA256SUMS, and BUILD-INFO.txt under dist/releases/<version>-<commit>/.

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
[[ "$release_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Expected a safe semantic version in Info.plist.'
[[ "$release_build" =~ ^[0-9]+$ ]] || fail 'Expected a numeric CFBundleVersion.'
release_parent="$PWD/dist/releases"
release_destination="$release_parent/$release_version-$release_short_commit"
[[ ! -e "$release_destination" ]] || fail 'Output for this version and commit already exists; retain it or move it before running again.'

# Fail before a lengthy build if repository content or history is unsuitable.
python3 scripts/audit-publication.py --history
release_architecture=''
mkdir -p "$release_parent"
release_stage="$(mktemp -d "$release_parent/.package.XXXXXX")"
trap 'if [[ -n "${release_stage:-}" && -d "$release_stage" ]]; then rm -rf "$release_stage"; fi' EXIT
python3 scripts/plugin_inventory.py --version "$release_version" --output "$release_stage"
for release_edition in full base; do
  if [[ "$release_edition" == full ]]; then
    release_app="$PWD/dist/CrossDiff.app"
  else
    release_app="$PWD/dist/editions/base/CrossDiff.app"
  fi
  bash scripts/build-app.sh --edition "$release_edition" --output "$release_app"
  cmp -s Resources/Info.plist "$release_app/Contents/Info.plist" || fail 'Built app metadata does not match the commit.'
  cmp -s "$release_stage/plugins.json" "$release_app/Contents/Resources/OfficialPlugins.json" || fail 'App and release catalogs differ.'
  for release_notice in LICENSE NOTICE ThirdParty/OpenCV/*; do
    cmp -s "$release_notice" "$release_app/Contents/Resources/$release_notice" || fail "The app is missing the current $release_notice."
  done
  codesign --verify --deep --strict "$release_app"
  python3 scripts/audit-publication.py --history --app "$release_app"
  architecture="$(/usr/bin/lipo -archs "$release_app/Contents/MacOS/CrossDiff" | tr ' ' '-')"
  [[ "$architecture" =~ ^(arm64|x86_64)(-(arm64|x86_64))?$ ]] || fail 'Unexpected app architecture.'
  [[ -z "$release_architecture" || "$release_architecture" == "$architecture" ]] || fail 'Edition architectures differ.'
  release_architecture="$architecture"
  release_app_name="CrossDiff-$release_version-$release_edition-macOS-$release_architecture.zip"
  # Omit resource forks, extended attributes, quarantine metadata and personal ACLs.
  /usr/bin/ditto --norsrc --noextattr --noacl --noqtn --nopersistRootless \
    -c -k --keepParent "$release_app" "$release_stage/$release_app_name"
  # ditto's Unix ZIP extra field otherwise retains local uid/gid.
  python3 - "$release_stage/$release_app_name" "$release_edition" <<'STRIP_ZIP_METADATA'
import os, sys, zipfile, plistlib
from pathlib import Path
sys.path.insert(0, 'scripts')
import plugin_inventory
archive_path = sys.argv[1]
clean_path = archive_path + '.clean'
with zipfile.ZipFile(archive_path) as source, zipfile.ZipFile(clean_path, 'w') as target:
    for entry in source.infolist():
        contents = source.read(entry)
        entry.extra = b''
        entry.comment = b''
        target.writestr(entry, contents)
os.replace(clean_path, archive_path)
metadata = plistlib.loads(Path('Resources/Info.plist').read_bytes())
catalog, packages = plugin_inventory.build_inventory(metadata['CFBundleShortVersionString'])
plugin_inventory.validate_app_archive(Path(archive_path), sys.argv[2], catalog, packages, metadata)
STRIP_ZIP_METADATA
  mkdir "$release_stage/verification"
  /usr/bin/ditto -x -k "$release_stage/$release_app_name" "$release_stage/verification"
  codesign --verify --deep --strict "$release_stage/verification/CrossDiff.app"
  rm -rf "$release_stage/verification"
done
require_clean
[[ "$(git rev-parse HEAD)" == "$release_commit" ]] || fail 'HEAD changed during the build; retry from one fixed commit.'
release_base_name="CrossDiff-$release_version-base-macOS-$release_architecture.zip"
release_full_name="CrossDiff-$release_version-full-macOS-$release_architecture.zip"
release_source_name="CrossDiff-$release_version-source.tar.gz"
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
Base application archive: $release_base_name
Full application archive: $release_full_name
Plugin catalog: plugins.json
Source archive: $release_source_name
INFO

# Inspect source archive names; application inventories were validated above.
python3 - "$release_stage/$release_source_name" "$release_version" <<'PY'
import sys, tarfile
from pathlib import PurePosixPath
source_archive, version = sys.argv[1:]
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
  shasum -a 256 CrossDiff-* plugins.json BUILD-INFO.txt > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
require_clean
[[ "$(git rev-parse HEAD)" == "$release_commit" ]] || fail 'HEAD changed during packaging; retry from one fixed commit.'
mv "$release_stage" "$release_destination"
release_stage=''
printf 'Prepared local release files: %s\n' "$release_destination"
printf 'Source commit: %s\nAd-hoc signed; not notarized. Nothing was uploaded.\n' "$release_commit"

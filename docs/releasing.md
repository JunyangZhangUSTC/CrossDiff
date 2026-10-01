# Preparing a release

CrossDiff currently builds local, **ad-hoc signed development previews**. The repository has no automatic publishing, Developer ID credentials, or notarization setup. The procedure here prepares reviewable files inside the repository; it does not create a GitHub release or upload anything.

## Before packaging

1. Complete the relevant checks in the [development guide](development.md). For application changes, include native window verification; CI compilation alone is insufficient. Record failures and unverified manual scenarios in [validation records](validation/README.md).
2. Update `Resources/Info.plist`, `CHANGELOG.md`, and both README versions for the intended preview. Keep `CFBundleShortVersionString` and the numeric `CFBundleVersion` consistent with the app being released.
3. Check the [license](../LICENSE), [copyright notice](../NOTICE), and [security policy](../SECURITY.md). Public source, examples, images, and screenshots must not contain private files, credentials, personal machine paths, or local session data.
4. Commit the exact release state. Packaging refuses tracked changes and untracked files; ignored development data stays outside the archives. Do not use `assume-unchanged` or `skip-worktree` to conceal source edits.

All development commands must use the project environment and write only inside the repository. Existing scripts load the environment automatically; load `scripts/project-env.sh` first for custom Bash commands.

## Create the artifacts

From a clean checkout of the intended release commit:

```sh
bash scripts/package-release.sh
```

The script audits repository content and Git history, builds the app, checks its version and license notices, verifies its signature, audits the built bundle, and creates:

```text
dist/releases/<version>-<commit>/
├── CrossDiff-<version>-macOS-<architecture>.zip
├── CrossDiff-<version>-source.tar.gz
├── BUILD-INFO.txt
└── SHA256SUMS
```

The app architecture comes from the built executable, not from an assumed download label. The app ZIP omits resource forks, extended attributes, personal ACLs, and Unix owner IDs stored in ZIP metadata. The script extracts a temporary project-local copy to verify the signature of the actual archive. The source archive is generated with `git archive` from the **same fixed commit**, so it contains tracked source rather than local build caches or `.git`. `BUILD-INFO.txt` records the full commit, version, architecture, and signing status without including the developer's machine paths. SHA-256 checksums cover both archives and the build information.

The script never changes source history, installs the app, invokes GitHub, or uploads artifacts. It refuses to overwrite an existing output directory for the same version and commit. Generated output remains ignored by Git.

To run the public-content audit separately:

```sh
source scripts/project-env.sh
python3 scripts/audit-publication.py --history --app dist/CrossDiff.app
```

Automated secret and path scans reduce mistakes but cannot establish that every published file is non-sensitive. Review findings and inspect human-facing assets before publishing.

## Keep source and binaries together

For each published app, make the exact corresponding source available alongside it. Use the source archive and full commit recorded by the package script. A GitHub tag should resolve to that commit; GitHub's automatic source downloads are useful, but do not substitute an unrelated branch snapshot for the app's source.

When a GitHub remote is configured, publish the reviewed source commit and tag, then attach the prepared ZIP, source archive, build information, and checksums to that tag's release. There is no repository URL hard-coded here. Verify the actual repository owner and destination before pushing or uploading.

CrossDiff is distributed under GNU AGPL v3. Preserve `LICENSE` and `NOTICE` in the app and source archives. Consult the license text for the applicable distribution obligations.

## Preview signing and public distribution

An ad-hoc signature allows local bundle integrity checks. It does **not** establish a publisher identity, prove notarization, or guarantee that Gatekeeper will accept a downloaded app. Describe this clearly in preview release notes and provide the source-build option. Do not tell users to disable macOS security protections globally.

A polished public binary release needs a separate Developer ID signing and Apple notarization workflow, including secure certificate handling, the required runtime/signing configuration, notarization submission, ticket stapling, and verification on another Mac. None of those steps are implemented by `package-release.sh`; do not label its output as notarized or alter its build information to imply that it is.

## Manual publication checklist

- [ ] The release commit is clean, versioned, and matches the tag.
- [ ] Both README versions and the changelog match implemented behavior; future features remain clearly marked.
- [ ] Relevant core and native checks passed; remaining limitations are stated in the release notes.
- [ ] Repository history and the built app passed the publication audit.
- [ ] Screenshots, sample files, archives, and notices received a final privacy and licensing review.
- [ ] The archive extracts correctly and its app signature verifies on the extracted bundle.
- [ ] The matching source archive, `BUILD-INFO.txt`, and `SHA256SUMS` are included.
- [ ] The architecture, minimum macOS version, and ad-hoc signing status are explicit.
- [ ] The intended remote repository and tag were verified before publication.
- [ ] After uploading, checksums are verified against the downloaded assets and their links work.

The workflow configures CI checks, not a release publisher. Record actual remote CI results only after they have run.

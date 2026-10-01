# Preparing a release

CrossDiff publishes **ad-hoc signed development previews** through [GitHub Releases](https://github.com/JunyangZhangUSTC/CrossDiff/releases). The [Release workflow](../.github/workflows/release.yml) builds an Apple silicon app and prepares a **draft pre-release** with matching source and checksums. A maintainer reviews the draft and chooses **Publish release** to make it available to users. A normal push to `main` runs the regular checks; it does not create a release.

The workflow uses GitHub's short-lived, repository-scoped `GITHUB_TOKEN`. It does not require a personal access token, Apple certificate, or notarization credentials. The app remains **unsigned by Developer ID and not notarized**; an ad-hoc signature is not an Apple developer identity.

## Before tagging

1. Complete the relevant checks in the [development guide](development.md). For application changes, include native window verification; CI compilation alone is insufficient. Record failures and unverified manual scenarios in [validation records](validation/README.md).
2. Update `Resources/Info.plist`, `CHANGELOG.md`, and both README versions for the intended preview. Keep `CFBundleShortVersionString` and the numeric `CFBundleVersion` consistent with the app being released.
3. Add bilingual release notes at `docs/releases/<version>.md`, using [0.4.0](releases/0.4.0.md) as a starting point. The file name omits the tag's `v` prefix. Describe implemented changes, requirements, signing status, and known limitations. The workflow reads these notes from the tagged commit.
4. Check the [license](../LICENSE), [copyright notice](../NOTICE), and [security policy](../SECURITY.md). Public source, examples, images, and screenshots must not contain private files, credentials, personal machine paths, or local session data.
5. Commit and push the exact release state to `main`. Packaging refuses tracked changes and untracked files; ignored development data stays outside the archives. Do not use `assume-unchanged` or `skip-worktree` to conceal source edits.

All development commands must use the project environment and write only inside the repository. Existing scripts load the environment automatically; load `scripts/project-env.sh` first for custom Bash commands.

## Create a release draft

The current preview is **0.4.0**. For a future **0.4.1** release, first update the version to `0.4.1`, increment the build number, add `docs/releases/0.4.1.md`, and commit the release changes. Then run from the repository root:

```sh
source scripts/project-env.sh
git switch main
git push origin main
git tag -a v0.4.1 -m "CrossDiff 0.4.1 preview"
git push origin v0.4.1
```

Use `v0.4.0` for the current version; the example is not a command to tag the existing 0.4.0 app as 0.4.1. The tag must exactly match `v` plus `CFBundleShortVersionString`. Its commit must be reachable from `origin/main`.

Pushing the version tag starts **Release** in [Actions](https://github.com/JunyangZhangUSTC/CrossDiff/actions/workflows/release.yml). You can also choose **Run workflow**, select `main`, and enter an **existing** remote tag. Manual dispatch does not create or move a tag.

The workflow:

1. Checks the tag, version, release notes, and source commit against `origin/main`.
2. Runs core behavior checks and compiles the integrated native workflow checks on the Apple silicon `macos-15` runner. Compiling native checks does not exercise real window interactions or prove visual correctness.
3. Runs the existing `scripts/package-release.sh` to build, audit, sign, and package that exact commit.
4. Creates a draft marked as a pre-release and attaches the application ZIP, corresponding source archive, `BUILD-INFO.txt`, and `SHA256SUMS`.

Open the completed run and review its results, then visit [Releases](https://github.com/JunyangZhangUSTC/CrossDiff/releases). Download the draft assets, check their contents and checksums, and review the notes before clicking **Publish release**. Keep the pre-release designation while CrossDiff is a development preview. Drafts are for maintainer review and do not provide a public download; the README points to the release list so published previews remain discoverable.

A retry may update an existing draft only for the same source commit. The workflow refuses to overwrite a published release or repurpose an existing draft for another commit. Do not move a released tag to fix a build; correct the source and use a new version. If a run fails, inspect the Actions log, correct the cause, and rerun only when the selected tag still identifies the intended source.

GitHub's documentation covers [managing draft and published releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) and the [automatic `GITHUB_TOKEN`](https://docs.github.com/en/actions/concepts/security/github_token).

## Create the same artifacts locally

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

The app architecture comes from the built executable, not from an assumed download label. The GitHub release workflow currently produces `arm64` only; local builds use the host architecture, and Intel releases have not been validated. No universal binary is produced.

The app ZIP omits resource forks, extended attributes, personal ACLs, and Unix owner IDs stored in ZIP metadata. The script extracts a temporary project-local copy to verify the signature of the actual archive. The source archive is generated with `git archive` from the **same fixed commit**, so it contains tracked source rather than local build caches or `.git`. `BUILD-INFO.txt` records the full commit, version, architecture, and signing status without including the developer's machine paths. SHA-256 checksums cover both archives and the build information.

The package script itself never changes source history, installs the app, invokes GitHub, or uploads artifacts. It refuses to overwrite an existing output directory for the same version and commit. Generated output remains ignored by Git. The separate GitHub workflow handles the draft and attachment uploads.

To run the public-content audit separately:

```sh
source scripts/project-env.sh
python3 scripts/audit-publication.py --history --app dist/CrossDiff.app
```

Automated secret and path scans reduce mistakes but cannot establish that every published file is non-sensitive. Review findings and inspect human-facing assets before publishing.

## Keep source and binaries together

For each published app, make the exact corresponding source available alongside it. Use the source archive and full commit recorded by the package script. The release tag must resolve to that commit; GitHub's automatic source downloads are useful, but do not substitute an unrelated branch snapshot for the app's source.

The publishing destination is [JunyangZhangUSTC/CrossDiff](https://github.com/JunyangZhangUSTC/CrossDiff). Local development uses this repository's SSH `origin`; Actions authenticates separately with its own short-lived token. No local SSH key or personal token needs to be uploaded as a release secret.

CrossDiff is distributed under GNU AGPL v3. Preserve `LICENSE` and `NOTICE` in the app and source archives. Consult the license text for the applicable distribution obligations.

## Preview signing and public distribution

An ad-hoc signature allows local bundle integrity checks. It does **not** establish a publisher identity, prove notarization, or guarantee that Gatekeeper will accept a downloaded app. Describe this clearly in preview release notes and provide the source-build option. Do not tell users to disable macOS security protections globally. First-launch instructions are available in both the [Chinese README](../README.md#首次在-macos-上打开) and [English README](../README.en.md#first-launch-on-macos).

A Developer ID signed and notarized distribution needs a separate workflow for secure certificate handling, the required runtime/signing configuration, notarization submission, ticket stapling, and verification on another Mac. Those steps are not implemented here; do not label the current output as notarized or alter its build information to imply that it is.

## Publication checklist

- [ ] The release commit is clean, versioned, on `main`, and matches the tag.
- [ ] Both README versions, the changelog, and bilingual release notes match implemented behavior; future features remain clearly marked.
- [ ] Relevant core and native checks passed; remaining limitations are stated in the release notes.
- [ ] The Release Actions run actually completed successfully; native compilation is not described as full UI verification.
- [ ] Repository history and the built app passed the publication audit.
- [ ] Screenshots, sample files, archives, and notices received a final privacy and licensing review.
- [ ] The archive extracts correctly and its app signature verifies on the extracted bundle.
- [ ] The matching source archive, `BUILD-INFO.txt`, and `SHA256SUMS` are included.
- [ ] The architecture, minimum macOS version, and ad-hoc signing status are explicit.
- [ ] After downloading the attached assets into a project-local directory, `shasum -a 256 -c SHA256SUMS` passes.
- [ ] The draft is reviewed before **Publish release**; public download links work afterward.

Record actual remote CI results only after they have run. A workflow definition or a compiled check program is not evidence that a particular release has passed every test.

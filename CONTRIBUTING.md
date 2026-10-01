# Contributing to CrossDiff

Thanks for helping make file comparison feel at home on the Mac. Bug reports, usability feedback, translations, documentation, and focused code changes are welcome. You can write issues and pull requests in English or 简体中文.

## Before you start

- Read the [README](README.en.md), [development guide](docs/development.md), and [roadmap](docs/roadmap.md).
- Search existing issues and pull requests before starting the same work.
- For a larger feature, explain the workflow and intended behavior in an issue first. Small fixes and documentation improvements can go straight to a pull request.
- Report security concerns through GitHub Issues as described in [SECURITY.md](SECURITY.md), using synthetic or redacted examples.

## Build and develop

Requirements: macOS 14 or later and a Swift toolchain that supports the Swift 6.0 package manifest. CrossDiff currently compiles in Swift 5 language mode. Apple Silicon and Intel builds use the architecture of the build machine.

From the repository root:

```sh
bash scripts/build-app.sh
bash scripts/open-dev-app.command
```

The app is built into `dist/CrossDiff.app`; the development launcher keeps sessions and preferences inside the repository. Nothing is installed into `/Applications`. For custom commands, use Bash and load the project environment first:

```sh
source scripts/project-env.sh
```

Keep development caches, temporary files, test fixtures, and output inside the project. Do not change `HOME`, install global dependencies, or use real user sessions or private files as test data. The [development guide](docs/development.md) lists the checks and their runtime requirements.

Release maintainers can follow the [release preparation guide](docs/releasing.md) to create an app archive and matching source from a clean commit. Packaging is local and never publishes automatically.

## Make a focused change

- Keep platform-independent comparison and persistence logic in `CrossDiffCore`. AppKit, SwiftUI, and interaction state belong in `CrossDiff`.
- Preserve exact source text, including UTF-16 offsets, composed characters, and line endings. Visual alignment and deletion previews must never enter saved source text.
- Editing and merging change the session; only an explicit save writes an original file. Preserve external-change detection and independent undo histories.
- Provide English and Simplified Chinese for app-owned UI text using the existing `L(中文, English)` convention.
- Use `ComparisonTheme` for colors and verify light, dark, and narrow-window appearances for UI changes.
- Keep slow work off the main thread and reject stale asynchronous results.
- Follow nearby Swift style and keep comments focused on decisions or non-obvious constraints.

## Validate and submit

Run the checks relevant to your change. Core behavior changes should pass `bash scripts/check.sh`; native interaction changes need the corresponding AppKit checks. Run native window checks **one at a time**. For documentation-only changes, check links and commands; an application rebuild is unnecessary.

A pull request should describe the problem, resulting behavior, and checks actually completed. Include before/after screenshots for visible changes when helpful, using synthetic content. State anything you could not verify; `--build-only` proves compilation, not UI behavior.

Do not commit build output, local preferences, test sessions, credentials, or screenshots containing personal data. Avoid unrelated formatting or generated-file changes. Contributions are made under the project's [GNU AGPL v3 license](LICENSE).

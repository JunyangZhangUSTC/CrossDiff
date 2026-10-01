# Development guide

CrossDiff is a native macOS application built with SwiftUI and AppKit. Its comparison, search, file I/O, and persistence logic live in a separate Swift module with no AppKit or SwiftUI dependency. The package currently has no third-party runtime dependencies.

For product behavior, see the [user guide](usage.md), [specification](specification.md), and [roadmap](roadmap.md). Contribution expectations are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Requirements

- macOS 14 or later.
- Xcode or Command Line Tools with a toolchain supporting the Swift 6.0 package manifest. The package uses Swift 5 language mode; see [Package.swift](../Package.swift).
- A logged-in macOS graphical session for native window behavior and rendering checks.

The build script produces an app for the current machine's architecture. It does not create a universal binary or install the app globally.

## Project-local environment

Run development commands from the repository root. Existing shell scripts load [scripts/project-env.sh](../scripts/project-env.sh) automatically. Before running a custom command in **Bash**, load it yourself:

```sh
source scripts/project-env.sh
```

This keeps temporary files, compiler caches, SwiftPM configuration, and development data in the project. Do not override `HOME` or install global dependencies. Use project-local synthetic fixtures, never real user files or the user's normal application session, for tests.

`CROSSDIFF_DATA_DIR` selects the session and preferences directory. The environment script defaults it to `.build/dev-sessions/` and rejects a development data directory outside the repository. Native test scripts use independent directories.

## Build and run

```sh
bash scripts/build-app.sh
codesign --verify --deep --strict dist/CrossDiff.app
bash scripts/open-dev-app.command
```

The output is `dist/CrossDiff.app`. You can also double-click `scripts/open-dev-app.command` in Finder. This launcher keeps runtime data local to the project. Opening the `.app` directly through Finder uses the ordinary application data directory, separate from development sessions.

The build script replaces the executable atomically and applies an ad-hoc signature. Quit an older app normally before opening the new build; an already running process does not acquire newly built code. Do not force-terminate it and risk unsaved work. This is a local development package, not a Developer ID signed or notarized release.

## Choose relevant checks

All commands below run from the repository root. Native window checks must run **serially** because they share the AppKit desktop session.

| Change | Command | Coverage |
| --- | --- | --- |
| Core comparison, merging, file I/O, folders, persistence, search and replacement | `bash scripts/check.sh` | Standalone behavior checks without XCTest |
| Native editing | `bash scripts/tests/check-editor.sh` | Independent undo, tab state, composition, theme and glyph visibility |
| Visual row alignment | `bash scripts/tests/check-alignment.sh` | Gap rows, wrapped lines, selections, undo and alignment toggles |
| Scroll layout | `bash scripts/tests/check-scroll-geometry.sh` | First line/column, gutter space, resizing and scrolling |
| Actual text rendering | `CROSSDIFF_CAPTURE_WINDOW=1 bash scripts/tests/render-native-ui.sh` | Native parent-window rendering, text contrast and difference highlights |
| Deletion preview | `bash scripts/tests/check-deletion-preview.sh` | Source isolation, strikethrough, copy behavior and light/dark layouts |
| Integrated workflows | `bash scripts/tests/check-workflow.sh` | Merge, search/replace, save/restore, menu shortcuts, toolbar actions, settings and languages |
| All behavioral suites | `bash scripts/check-all.sh` | Core plus serialized editor, alignment, geometry, preview and workflow checks |
| Release publishing | `source scripts/project-env.sh` then `python3 -m unittest discover -s scripts/tests -p 'test_github_release.py'` | Offline checks for version matching, draft retries, upload protection and download verification |

`check-all.sh` does not invoke the separate `render-native-ui.sh` capture entry point or build the release app. Run those when appropriate. The rendering check writes images to `.build-ui-checks/renders/`. Set `CROSSDIFF_INPUT_STYLE=white-attributed`, `prefilled`, or `ime-commit` to exercise imported text colors, restored content, or input-method commits; the default uses ordinary input.

Native checks need a usable AppKit session. A timeout or an unavailable window server is not a pass. Where supported, `--build-only` verifies that the check program compiles; it does not exercise a real window. Inspect light, dark, and minimum-width windows after UI changes, including their parent-view composition. An HTML mockup or isolated text view cannot establish that the actual app renders correctly.

The checks isolate the real system input method and invoke native text input APIs to test marked text and commits. They do not use the general system clipboard for test data. Physical input-method candidate windows, Finder drag-and-drop, system file dialogs, VoiceOver, and extended everyday use still require manual verification.

With a complete Xcode installation, the standard XCTest target can also run:

```sh
source scripts/project-env.sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

Some Command Line Tools installations do not include XCTest; use the standalone core checks in that environment. `--disable-sandbox` affects SwiftPM build subprocesses, not macOS security settings.

## Release preparation

See [Preparing a release](releasing.md) for clean-commit packaging, publication audits, corresponding source archives, and the distinction between local ad-hoc signatures and public notarized distribution. `bash scripts/package-release.sh` prepares local artifacts only; it does not upload them.

## Continuous integration

[.github/workflows/check.yml](../.github/workflows/check.yml) configures a macOS runner to check patch formatting, audit repository history, run core and release-publishing checks, compile the integrated native checks, and build, verify, and audit the app. Compilation on CI does not replace native window interaction and pixel checks. Report a remote CI result only after that workflow has actually run.

[.github/workflows/release.yml](../.github/workflows/release.yml) builds version tags and prepares verified draft pre-releases. See the [release guide](releasing.md) for tagging, reviewing, and publishing a preview.

Record release-specific results and unverified items under [docs/validation/](validation/README.md). Historical logs describe their original test run, not a guarantee for every subsequent commit.

## Repository map

```text
CrossDiff/
├── Sources/
│   ├── CrossDiff/             # macOS UI, native editors, app state
│   └── CrossDiffCore/         # Comparison, search, file I/O, persistence
├── Checks/                    # Core behavior checks without XCTest
├── Tests/CrossDiffCoreTests/  # Standard XCTest target
├── Resources/                 # Application metadata and brand assets
├── examples/                  # Small, synthetic comparison samples
├── scripts/                   # Local build, launcher, environment and checks
│   └── tests/                 # Native AppKit checks and render programs
├── docs/                      # Product, user and development documentation
│   └── validation/            # Versioned verification records
├── .github/                   # CI and contribution templates
├── Package.swift
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

Build output, local editor configuration, and temporary development data are ignored by Git. Make changes in source files, never generated app copies.

## Current implementation limits

These limits are deliberate product boundaries, not silent data conversions:

- Text files support UTF-8, UTF-8 BOM, and BOM-marked UTF-16 LE/BE, up to 20 MB. Very large changes can fall back to coarse differences with an in-app notice.
- Search and replacement use literal matching, with optional case-insensitive matching. Navigation displays at most 10,000 matches per side. Replace All processes all matches in its selected scope, even when navigation is capped. A result exceeding 64 × 1024 × 1024 UTF-16 code units on either target cancels that replacement without publishing a partial edit.
- Image comparison uses an 8-bit sRGB preview with the longest edge limited to 1600 pixels. Zoom works on that preview; only the first frame of an animated image is compared. It is not a lossless full-resolution pixel verifier.
- Folder copying supports regular files, with a preview and revalidation before execution. It does not follow/copy symbolic links, delete batches, or perform full directory synchronization. Completed copies remain if a later item fails; the UI asks for a new comparison.
- Sessions save on a serial background queue and flush the latest snapshot at termination. Manual file saves still run synchronously. Very large layouts and slow disks remain performance work.
- PDF, Word, spreadsheets, three-way merging, syntax highlighting, unified diff view, context folding, and report export are future work. See the [roadmap](roadmap.md).

Normal app data lives in `~/Library/Application Support/CrossDiff/`: `sessions.json` for local restoration and `preferences.json` for language and appearance. Files are owner-readable/writable, not encrypted by the application. See [SECURITY.md](../SECURITY.md) for the privacy boundary.

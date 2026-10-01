# Development guide

CrossDiff is a native macOS application built with SwiftUI and AppKit. Its comparison, search, file I/O, and persistence logic live in a separate Swift module with no AppKit or SwiftUI dependency. The package currently has no third-party runtime dependencies.

For product behavior, see the [user guide](usage.md), [specification](specification.md), and [roadmap](roadmap.md). Contribution expectations are in [CONTRIBUTING.md](../CONTRIBUTING.md).

The next framework direction is documented separately in the [product vision](product-vision.md), [architecture proposal](architecture/compare-everything.md), and [draft plugin guide](plugins/development.md). The broader architecture remains a proposal. The implemented experimental contract includes a JavaScriptCore helper and native table, document-page, and archive-tree renderers. Version 0.8.0 packages Base and Full editions with a shared offline official-plugin catalog; see the [implemented API](plugins/development.en.md). Shared comparison terms are in the [glossary](../GLOSSARY.md), with accepted design decisions under [docs/adr](adr/0001-comparison-modes.md).

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

The default build is **Full**: text, folders, images, Hex, the Archive plugin, and PDF. The output is `dist/CrossDiff.app`. You can also double-click `scripts/open-dev-app.command` in Finder. This launcher keeps runtime data local to the project. Opening the `.app` directly through Finder uses the ordinary application data directory, separate from development sessions.

The build script replaces the executable atomically and applies an ad-hoc signature. Quit an older app normally before opening the new build; an already running process does not acquire newly built code. Do not force-terminate it and risk unsaved work. This is a local development package, not a Developer ID signed or notarized release.

### Build an edition

Both editions compile the same host and renderers. **Base** bundles Archive; **Full** adds PDF. The independently packaged JSON example is not bundled in either edition.

```sh
# Explicit Full build (the default).
bash scripts/build-app.sh --edition full

# Base build at the same default development-app location.
bash scripts/build-app.sh --edition base
bash scripts/open-dev-app.command

# Keep a separate Base artifact without replacing dist/CrossDiff.app.
bash scripts/build-app.sh --edition base --output dist/editions/base/CrossDiff.app
codesign --verify --deep --strict dist/editions/base/CrossDiff.app
```

The project launcher opens the edition currently built at `dist/CrossDiff.app`. Outputs must remain inside the project and be named `CrossDiff.app`; custom output locations do not change where the launcher opens the app. Both editions use the same application identity and data layout. When switching editions, a bundled plugin takes precedence over an external installation with the same ID; the external registration, enablement state, and version history are retained for switching back.

### Official plugin inventory and installation

[scripts/plugin_inventory.py](../scripts/plugin_inventory.py) is the explicit source of truth for edition contents and release plugin assets. It generates byte-identical `OfficialPlugins.json` resources for both apps and `plugins.json` for the Release, with exact package sizes, complete-file SHA-256 values, plugin identities and versions, and fixed URLs for that app release. Adding a development example does not automatically add it to Full or the official catalog.

The app reads the bundled catalog without contacting the network. In **New… → More Comparisons** or **CrossDiff → Plugins…**, an explicit **Download & Install** action downloads an uninstalled official plugin. Before installation, it checks the complete package's size and digest, ID, version, host compatibility, and restricted JavaScript runtime. Cancellation and failures leave installation state unchanged. This path installs and enables the verified package without another permission sheet; it cannot authorize native code or silently replace an installed plugin.

Existing external plugins can be updated through the local-file or arbitrary-HTTPS review flow. Plugins already bundled with the running edition update with the app and cannot be overwritten by external packages. Native full-trust plugins retain explicit review and approval; see [SECURITY.md](../SECURITY.md). There is no background catalog polling or automatic update service. The fixed GitHub URLs become downloadable after the corresponding release is published.

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
| New comparison flow | `bash scripts/tests/check-new-comparison-workflow.sh` | Type chooser, left/right drafts, native controls, cancellation, plugin handoff, deferred file opening and bilingual light/dark sheets |
| Image rendering | `bash scripts/tests/check-image-comparison.sh` | Crop alignment, corner resizing, aspect ratio, independent axes, flips, rotation, coverage, transparency, preview limits and cancellation |
| Native image workflows | `bash scripts/tests/check-image-workflow.sh` | Per-side sliders and numeric fields, corner handles, aspect lock, flip buttons, dragging, reset, tab state, source isolation, and actual light/dark windows |
| Binary core and detection | `bash scripts/tests/check-binary-core.sh` and `bash scripts/tests/check-binary-detection.sh` | Byte alignment, bounded work, cancellation, metadata changes, 64-bit reads and content sniffing |
| Native binary workflows | `bash scripts/tests/check-binary-workflow.sh` | Routing, gaps, source addresses, bounded paging, menu guards, session persistence and actual bilingual light/dark/narrow windows |
| Archive reading and plugin | `bash scripts/tests/check-archives-core.sh` and `bash scripts/tests/check-archive-plugin.sh` | Streaming content verification, malicious/corrupt archives, budgets, canonical paths, real JS classifications and content groups |
| Native archive workflows | `bash scripts/tests/check-archive-workflow.sh` | Archive/folder routing, result validation, cancellation, plugin lifecycle, immutable sources, native tree filters and bilingual light/dark windows |
| Plugin packages and lifecycle | `bash scripts/tests/check-plugins-core.sh` | Integrity, immutable versions, native trust, malformed packages, rollback and storage boundaries |
| Plugin processes | `bash scripts/tests/check-plugin-runtime.sh` | Real JavaScript/native execution, absence of I/O APIs, timeout, cancellation and bounded outputs |
| Plugin downloading and management | `bash scripts/tests/check-plugin-download.sh` and `bash scripts/tests/check-plugin-manager.sh` | Offline transport, HTTPS policy, size/cancel bounds, damaged-plugin recovery and install state |
| Official catalog and installation | `bash scripts/tests/check-official-plugins.sh` | Offline discovery, exact package integrity and identity, restricted-only automatic installation, cancellation, failures, and Base/Full data preservation |
| Official plugin window | `bash scripts/tests/check-official-plugin-ui.sh` | Bundled/downloadable cards, offline browsing without installation changes, and actual bilingual light/dark/minimum-width rendering |
| PDF domain | `bash scripts/tests/check-pdf.sh` | Page alignment, scanning limits, extraction, malformed inputs and source preservation |
| Native plugin workflows | `bash scripts/tests/check-plugin-workflow.sh` | Install, disable, recovery, real external algorithm, PDF/page/table views and themes |
| All behavioral suites | `bash scripts/check-all.sh` | Core, image, plugin packages/runtime/download/manager/official catalog, PDF, binary and archives; release/inventory safeguards; serialized native text, image, plugin, official-plugin, binary and archive workflows |
| Edition packaging and plugin inventory | `source scripts/project-env.sh` then `python3 -m unittest discover -s scripts/tests -p 'test_plugin_inventory.py'` | Base/Full contents, matching standalone packages, catalog checksums and URLs, safe output locations, and invalid metadata rejection |
| Release publishing | `source scripts/project-env.sh` then `python3 -m unittest discover -s scripts/tests -p 'test_github_release.py'` | Offline checks for version matching, draft retries, upload protection and download verification |

`check-all.sh` does not invoke the separate `render-native-ui.sh` capture entry point or build the release app. Run those when appropriate. The text rendering check writes images to `.build-ui-checks/renders/`; image workflow captures are in `.build-image-workflow-checks/renders/`. Set `CROSSDIFF_INPUT_STYLE=white-attributed`, `prefilled`, or `ime-commit` to exercise imported text colors, restored content, or input-method commits; the default uses ordinary input.

Native checks need a usable AppKit session. A timeout or an unavailable window server is not a pass. Where supported, `--build-only` verifies that the check program compiles; it does not exercise a real window. Inspect light, dark, and minimum-width windows after UI changes, including their parent-view composition. An HTML mockup or isolated text view cannot establish that the actual app renders correctly.

The checks isolate the real system input method and invoke native text input APIs to test marked text and commits. They do not use the general system clipboard for test data. Physical input-method candidate windows, Finder drag-and-drop, system file dialogs, VoiceOver, and extended everyday use still require manual verification.

With a complete Xcode installation, the standard XCTest target can also run:

```sh
source scripts/project-env.sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
```

Some Command Line Tools installations do not include XCTest; use the standalone core checks in that environment. `--disable-sandbox` affects SwiftPM build subprocesses, not macOS security settings.

## Release preparation

See [Preparing a release](releasing.md) for clean-commit Base/Full packaging, standalone official and example plugins, catalog verification, publication audits, matching source archives, and the distinction between local ad-hoc signatures and public notarized distribution. `bash scripts/package-release.sh` prepares local artifacts only; it does not upload them.

## Continuous integration

[.github/workflows/check.yml](../.github/workflows/check.yml) configures a macOS runner to check patch formatting, audit repository history, run core, image-rendering, plugin/PDF, official-catalog, inventory, and release-publishing checks, run archive and binary core checks, compile the text, new-comparison, image, plugin, official-plugin, binary and archive native workflow checks, and build, verify, and audit the app. Compilation on CI does not replace native window interaction and pixel checks. Report a remote CI result only after that workflow has actually run.

[.github/workflows/release.yml](../.github/workflows/release.yml) builds version tags, checks core, image, plugins/PDF, official-catalog and edition/release safeguards, compiles native workflow checks, and prepares verified draft prereleases containing Base, Full, standalone plugins, the catalog, matching source and checksums. Published and immutable releases are not overwritten by retries. See the [release guide](releasing.md) for tagging, reviewing, and publishing a preview.

Record release-specific results and unverified items under [docs/validation/](validation/README.md). Historical logs describe their original test run, not a guarantee for every subsequent commit.

## Repository map

```text
CrossDiff/
├── Sources/
│   ├── CrossDiff/             # macOS UI, native editors, app state
│   ├── CrossDiffCore/         # Comparison, I/O, persistence and plugin contracts
│   └── CrossDiffPluginHost/   # Restricted JavaScriptCore worker
├── Plugins/                   # Official PDF/archive sources and an independent JSON example
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

- Archive comparisons are an official bundled restricted plugin with a native tree renderer. They decode bounded streams without extracting to disk. ZIP/TAR and compressed TAR formats, path rules, source budgets and unverified-link behavior are described in the [usage guide](usage.md#archives). The core dynamically loads system libarchive for ZIP and compression filters; TAR headers/names are independently bounded and validated. Gzip integrity is independently checked with system zlib; XZ headers and all blocks are preflighted before decoder allocation, and recursive compression-filter detection is disabled. No bundled native library, global dependency or external decompressor is installed.
- Binary comparisons are read-only, with an 8 GiB limit per regular local file. The byte reader uses a held descriptor and bounded reads; the canvas draws a bounded page rather than allocating all rows. Complex regions may have approximate alignment and are explicitly marked. Metadata checks detect ordinary changes and replacement, not an immutable filesystem snapshot. Binary editing, patch export and remote binary sources are not implemented.
- Text files support UTF-8, UTF-8 BOM, and BOM-marked UTF-16 LE/BE, up to 20 MB. Very large changes can fall back to coarse differences with an in-app notice.
- Search and replacement use literal matching, with optional case-insensitive matching. Navigation displays at most 10,000 matches per side. Replace All processes all matches in its selected scope, even when navigation is capped. A result exceeding 64 × 1024 × 1024 UTF-16 code units on either target cancels that replacement without publishing a partial edit.
- Image comparison uses 8-bit sRGB previews. Both sources are decoded at the same scale with a 1600-pixel longest-edge limit; the transformed common canvas is also limited to 1600 pixels. Rendering runs in the background with cancellation and stale-result checks. Each image axis supports 10–400% scaling; rotation, flips, and translation are also manual. View zoom magnifies the resulting preview. Aspect lock is on by default and preserves the current proportions when relocked. Its Scale control displays the larger axis percentage, scales both axes proportionally, and stops both when either reaches a limit. Corner resizing anchors the opposite corner along the image’s transformed local axes and clamps at the minimum size rather than flipping implicitly. Perspective and free-form warping are not supported. Overlap-only differences use the intersection of transformed image coverage, including transparent pixels. Only the first frame of an animated image is compared. Resampling and compression can create residual differences; this is not automatic image registration or a lossless full-resolution pixel verifier.
- Image alignment and viewing state belong to the comparison tab and survive tab switching. These adjustments never write source images and are not saved across app restarts.
- Folder copying supports regular files, with a preview and revalidation before execution. It does not follow/copy symbolic links, delete batches, or perform full directory synchronization. Completed copies remain if a later item fails; the UI asks for a new comparison.
- Sessions save on a serial background queue and flush the latest snapshot at termination. Manual file saves still run synchronously. Very large layouts and slow disks remain performance work.
- PDF uses read-only snapshots: up to 48 MiB per file, the first 200 pages, bounded extracted text and 384 px page fingerprints. It is preview/text analysis, not exact full-resolution visual equality or OCR. Scanned pages need manual visual review.
- Plugin v1 uses bounded single-file JSON packages and three native result schemas: `table`, `documentPages`, and `archiveTree`. The official catalog installs missing restricted plugins only; existing external-plugin updates retain review, and bundled plugins update with the app. Restricted JavaScript has no host I/O APIs; native full-trust code is not sandboxed and quarantined executables are refused. Custom native views, assets/dependency loading, remote sources, Word, spreadsheets, three-way merging, syntax highlighting, unified diff view, context folding, and report export are future work. See the [roadmap](roadmap.md).

Normal app data lives in `~/Library/Application Support/CrossDiff/`: `sessions.json` for local restoration and `preferences.json` for language and appearance, `Plugins/` for external packages and version state, and `plugin-preferences.json` for bundled-plugin enablement. Files are owner-readable/writable, not encrypted by the application. See [SECURITY.md](../SECURITY.md) for the privacy boundary.

<div align="center">

<img src="Resources/Brand/hero.png" alt="CrossDiff — Native comparisons for macOS. Text, folders, and images." width="100%">

**See what changed. Keep your files to yourself.**

A free, open-source comparison app built for the Mac.<br>
Native controls. Thoughtful details. Everything stays local.

[简体中文](README.md) · [English](README.en.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-304A68?style=flat-square)](#get-started)
[![Swift](https://img.shields.io/badge/Built_with-Swift-F05138?style=flat-square)](Package.swift)
[![AGPL v3](https://img.shields.io/badge/License-AGPL_v3-22816B?style=flat-square)](LICENSE)
[![Preview](https://img.shields.io/badge/Status-Developer_preview-7C6DAA?style=flat-square)](CHANGELOG.md)

[Explore](#made-for-everyday-comparisons) · [Get started](#get-started) · [Privacy](#your-work-stays-on-your-mac) · [Roadmap](#growing-in-the-open) · [Contribute](CONTRIBUTING.md)

</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/text-en-dark.png">
  <img src="docs/assets/screenshots/text-en-light.png" alt="CrossDiff comparing code side by side with aligned lines and precise red and green character highlights" width="100%">
</picture>

<p align="center"><sub>A real CrossDiff window with synthetic sample text. Light and dark appearances follow your GitHub theme.</sub></p>

## Made for everyday comparisons

Compare a quick paste, review two code files, inspect a directory, or see what changed in an image. CrossDiff keeps the work in one quiet, focused workspace.

| | |
| :--- | :--- |
| **Native to the Mac**<br>SwiftUI and AppKit, native text editing, familiar menu commands, and Mac keyboard shortcuts. No bundled browser. | **Private by design**<br>No uploads, accounts, analytics, or application network requests. Compare files without an internet connection. |
| **Free & open source**<br>AGPL v3 source you can inspect, build, and modify. No subscription, trial clock, or feature paywall. | **Details you can trust**<br>Character and line differences, aligned rows, Unicode-aware text, and a clear view of both additions and deletions. |
| **You control the changes**<br>Edit either side, merge one block, undo independently, and save when ready. Comparing never overwrites source files. | **A considered workspace**<br>Light and dark themes, restrained highlights, comparison tabs, synchronized scrolling, and English / 简体中文. |

## One app, several ways to compare

| Compare | Available today |
| :--- | :--- |
| **Text & code files** | Paste or open two texts; inspect character or line changes; edit either side; merge individual blocks; find and replace; retain independent undo histories. |
| **Folders** | Scan recursively, filter differences, inspect changed and one-sided files, and preview additions or overwrites before copying selected files. |
| **Images** | Compare side by side, overlay, drag a wipe divider, inspect a difference image, and zoom. |

The **Show Deletions** view adds removed text to the right-hand review as red strikethroughs. It is off by default and read-only; review marks never enter your saved source. Standard copy returns original text, while an explicit revision-copy action includes the changes.

<details>
<summary><b>See the deletion review</b></summary>
<br>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/deletions-en-dark.png">
  <img src="docs/assets/screenshots/deletions-en-light.png" alt="CrossDiff showing removed content as red strikethroughs beside the edited source" width="100%">
</picture>
</details>

## Get started

**Current preview: 0.4.0.** Requires **macOS 14+**. A prebuilt app does not require a Swift toolchain.

This preview has been verified on **Apple silicon (arm64)**. Intel builds have not yet been validated.

**Build from source:** use a toolchain that supports **Swift 6.0 package manifests**, then run the following from a checkout. The project uses Swift 5 language mode and builds for your Mac's architecture.

```sh
bash scripts/build-app.sh
bash scripts/open-dev-app.command
```

The app is created at `dist/CrossDiff.app`. The project launcher keeps development sessions, preferences, and caches inside the checkout. Nothing is installed globally or into `/Applications`.

### First launch on macOS

**This preview does not yet have an Apple Developer ID signature or Apple notarization.** Local builds use an ad-hoc signature. macOS may therefore ask you to approve a downloaded copy manually.

After checking the download's source and its published `SHA256SUMS`:

1. Extract the app and try opening **CrossDiff.app** once.
2. If macOS blocks it because the developer cannot be verified, open **System Settings → Privacy & Security**, scroll to **Security**, and choose **Open Anyway** for CrossDiff.
3. Confirm **Open** and authenticate if prompted. Later launches normally use the saved exception.

This follows [Apple's app-opening guidance](https://support.apple.com/en-us/102445); there is no need to disable Gatekeeper system-wide. See the [release guide](docs/releasing.md) for signing and packaging details.

**Open source makes the app inspectable:** review the code, check the matching release source and checksums, or build it yourself. CrossDiff compares locally without uploading your files. Open source and checksums support verification; they are not a blanket guarantee that every build or download is safe.

**Try it in a minute**

1. Paste text into the two panes, or click **Open…** to select files or folders. Multiple inputs can be paired into separate comparison tabs.
2. Move through differences, edit either side, and merge only the blocks you choose.
3. Save explicitly. Use **Clear Both** for a fresh comparison, with an immediate restore action if needed.

The repository includes [two small Swift examples](examples/) to explore. See the [user guide](docs/usage.md) for behavior and the full shortcut list.

| Action | Shortcut |
| :--- | :--- |
| Open files or folders | ⌘O |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Find / find and replace | ⌘F / ⌥⌘F |
| Next / previous match | ⌘G / ⇧⌘G |
| Next / previous difference | ⌥⌘↓ / ⌥⌘↑ |
| Save the focused side | ⌘S |
| Settings / language | ⌘, |

Find **设置/Setting…** in the CrossDiff menu, then **语言/Language** to switch between English and 简体中文. The interface updates immediately.

## Your work stays on your Mac

CrossDiff performs comparison and editing locally. The application has no networking, telemetry, cloud sync, account system, or automatic update service. Using the app does not send document contents to a server.

Temporary comparisons can be restored from local session files. Normal launches store them in `~/Library/Application Support/CrossDiff/`; the project launcher uses an isolated project directory. **These files contain plain text and paths, and are not encrypted by CrossDiff.** You can clear local session history from the Session menu. Files in a cloud-synced folder remain subject to that folder's own sync behavior.

See the [privacy and security notes](SECURITY.md) for scope and responsible reporting. README badges and GitHub itself are external web services; they are not part of the desktop app.

## Growing in the open

CrossDiff is under active development, starting with dependable daily text, folder, and image comparison. Planned work includes:

- Context folding, clearer folder workflows, and accessibility polish.
- PDF comparison for papers and documents.
- Later: structured tables, Word documents, three-way merging, and export.

**PDF, Word, spreadsheets, and three-way merging are not available yet.** Images currently use previews up to 1600 px on the longest edge, text files have a 20 MB limit, and folder operations do not provide full synchronization. Read the [implementation limits](docs/development.md#current-implementation-limits), [roadmap](docs/roadmap.md), and [changelog](CHANGELOG.md).

## Build with us

Bug reports, translations, design feedback, and focused improvements are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md); the [development guide](docs/development.md) covers architecture, local builds, and tests.

```sh
bash scripts/check.sh       # Core behavior, no XCTest dependency
bash scripts/check-all.sh   # Full suite; requires a native macOS session
```

## License

Copyright © 2026 **Junyang Zhang**. CrossDiff is licensed under the [GNU Affero General Public License v3.0](LICENSE) (`AGPL-3.0-only`). See [NOTICE](NOTICE) for the copyright notice.

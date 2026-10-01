# 0.6.0 validation — built-in binary comparison

Local development validation on 2026-10-01, macOS 26.6.2 / Apple silicon, Swift 6.3.3 in Swift 5 language mode. Every generated file, fixture, session, cache and application remains inside this repository. No real user files, sessions or system clipboard contents are used as fixtures.

## Behavior and native rendering

- **479 binary core assertions passed.** They cover empty/equal inputs, modifications, insertion/deletion alignment at row and 1 MiB read boundaries, repeated content, deterministic edit fuzzing, complete source coverage and reconstruction, explicit budget fallback, cooperative cancellation, metadata changes/replacement/truncation, rejected special files, concurrent positional reads and offsets above 4 GiB.
- **8 detection groups passed.** They cover UTF-8 and BOM-marked UTF-16, incomplete sample boundaries versus malformed EOF, control bytes, empty inputs, bounded sampling above the text size ceiling and refusal of directories/FIFOs/symlinks/non-file URLs. Detection is a hint over at most 8 KiB, not whole-file encoding validation.
- Native binary workflow checks exercise ordinary and forced routing, mixed text/binary input, aligned gaps and both source addresses, row-width mapping, difference navigation, actual pointer selection without touching the clipboard, readonly menu/save guards, persisted paths without content, 24 MiB paging and stale read supersession, file mutation invalidation/reload and canceled comparisons.
- Real parent-window captures verify visible byte text and red highlights in Chinese light/dark at 1220 pt and English/Chinese at 860 pt. Hex and ASCII are drawn in the actual AppKit canvas, not an HTML prototype or a standalone isolated child.
- Existing core behavior checks passed. Existing text workflow checks passed, including editing, search/replacement, save, undo, settings, menus, and folder/image translations. Existing plugin workflow checks passed, including local install, real JSON execution, PDF page/text views and native image routing.

Reproduce with:

```sh
bash scripts/tests/check-binary-core.sh
bash scripts/tests/check-binary-detection.sh
bash scripts/tests/check-binary-workflow.sh
bash scripts/check.sh
bash scripts/tests/check-workflow.sh
bash scripts/tests/check-plugin-workflow.sh
```

Native suites run serially in a usable macOS AppKit session. Binary window captures and logs are in ignored `.build-binary-workflow/renders/`. Scrolling away and back during an in-flight read, changing 8/16 columns, and recreating a tab also have explicit regression checks.

## Boundaries

Each binary input is limited to 8 GiB; this is a safety ceiling, not a claim of exhaustive performance testing at that size. Source offsets and virtual rows use 64-bit values. The reader holds regular-file descriptors and validates ordinary metadata/path changes, but does not promise a filesystem snapshot against hostile metadata-preserving mutation. The view loads at most 512 rows per page and comparison work/span budgets can trigger explicitly identified approximate alignment. It never labels unconfirmed bytes as equal.

Sources are readonly. Binary editing, merging, patches, binary search, remote binary inputs and three-way Hex are not implemented. Copy selection is restricted to the loaded page. The current native accessibility labels and keyboard scrolling are present; VoiceOver, physical trackpad/Finder interaction and extended everyday use still require manual verification. Intel, physical macOS 14 and remote CI were not run in this local validation.

## Build and publication checks

`bash scripts/build-app.sh` produced `dist/CrossDiff.app` version 0.6.0 (build 14); `codesign --verify --deep --strict` passed. The build uses ad-hoc signing, not Developer ID signing or notarization. The existing SDK debug-path remapping emitted module-cache lookup warnings during linking; compilation and signing completed. The source/application publication audit and `git diff --check` passed. The heuristic audit is not a security guarantee.

A native column-switch check initially required the identical row-start byte after switching 8 to 16 columns. That expectation was corrected: the previous first byte must remain in the new first row, which may start up to 8 bytes earlier. The application behavior did not require a change for that assertion. The corrected final native suite passed, including tab scroll restoration and column-width changes.

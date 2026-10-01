# 0.7.1 validation — new comparison flow

Environment: Apple silicon macOS, Swift 6.3.3 in Swift 5 language mode. Fixtures, settings, session data, caches and native captures remain in ignored project-local directories. No real user files, sessions or system clipboard are used.

## Results

- `bash scripts/check.sh`: all core behavior checks passed.
- `bash scripts/tests/check-new-comparison-workflow.sh`: **123 assertions passed** against the production native window and attached sheet. Coverage includes actual toolbar/type/back/swap/create/More button presses, native text input, native file-picker cancellation, exact Unicode and newline preservation, mixed temporary/file inputs, file encoding and signatures, invalid inputs, draft isolation, asynchronous cancellation, disabled plugins, deferred Finder opens and legacy batch pairing. Mixed text tabs correctly name the temporary side.
- The existing `check-workflow.sh` suite was compiled and its isolated executable run successfully: merging, independent undo, search/replace, save/recovery, clear/restore, native keyboard commands, toolbar actions, settings and live localization passed.
- Twelve attached-sheet captures cover both languages and appearances, including an entire main-window frame of **860 × 580**. Assertions verify that the sheet fits the available content height. Actual chooser, text/folder input pages and the main toolbar were visually inspected. Captures are in `.build-new-comparison-workflow/renders/`.
- `bash scripts/build-app.sh` produced **0.7.1 (16)** at `dist/CrossDiff.app`; `codesign --verify --deep --strict dist/CrossDiff.app` passed. Logs are under `.scratch/new-comparison/`.

The new native suite is included in `scripts/check-all.sh` and compiled by CI using `--build-only`. No remote CI or GitHub release run is claimed. Compilation alone is not native interaction evidence.

## Remaining manual checks

Physical macOS 14 and Intel hardware, end-to-end VoiceOver, real input-method candidate windows, and Finder mouse-driven selection/drop gestures remain manual checks. The suite exercises native picker cancellation and the production file acceptance paths, without automating Finder itself. The app remains ad-hoc signed, without Developer ID signing or notarization.

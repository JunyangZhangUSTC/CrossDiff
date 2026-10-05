# Overflowing comparison tabs — 0.15.0 build 35

Date: 2026-10-05. Checked in real AppKit windows on Apple silicon macOS. Fixtures, caches, logs, captures and application bundles remained inside this checkout; real user sessions were not used.

## Failure and repair

The original horizontal SwiftUI scroll view disabled its indicators and did not reveal a newly selected session. The reproducer created 12 long-name sessions: a 3,908-point document inside a 1,220-point viewport stayed at offset zero when the last session became active. The actual selected accessibility card was outside the viewport, and the baseline check exited with status 8.

`SessionTabStrip` retains the existing SwiftUI session cards inside a native scroll view. A small native horizontal scroller occupies a stable bottom lane and appears only while the strip overflows and the pointer is over it (or the knob is being dragged). Wheel input over the cards, scroller and lane reaches the same viewport; ordinary vertical mouse-wheel input also browses horizontally.

The active card is revealed after selection, creation, closure and viewport resizing. Title reflow keeps an already visible active card visible. It does not pull the viewport back after the user deliberately scrolls elsewhere. The first implementation failed this last regression when the active session's dirty marker changed; requiring full containment of the previously visible card corrected it.

The scroller is managed separately from the scroll view because Apple's [overlay-scroller policy](https://developer.apple.com/documentation/appkit/nsscrollview/autohidesscrollers) does not make `autohidesScrollers` a persistent hover-visibility control; [flashing scrollers](https://developer.apple.com/documentation/appkit/nsscrollview/flashscrollers()) is temporary.

## Completed checks

| Check | Result |
| --- | --- |
| `bash scripts/tests/check-session-tabs.sh` (build and run phases separately) | 30 native assertions passed |
| Selection and layout | First/middle/last selection, new tabs, closing preceding tabs, long/short titles and resizing to 860 points retain a fully visible active card |
| Pointer input | Hover entry/exit, native knob dragging, horizontal and ordinary vertical wheel input, and direct wheel delivery over the scroller and its lane passed |
| Manual browsing | An unrelated edit and clean-to-dirty transition retain the user's chosen scroll position |
| Session count | Two fitting tabs show no scroller; two-to-one removes the strip; one-to-two restores a visible selection |
| Appearance | Actual Chinese/English, light/dark and 860/1,220-point windows captured; final light hover and dark narrow captures visually reviewed |
| Existing full-window workflow | Passed: aligned rows, merge, independent undo, search/replace, deletion preview mapping, copy, manual save/recovery, clear/restore, native keyboard commands, settings isolation and bilingual menus |
| Full and Base builds | Both built as 0.15.0 build 35; `codesign --verify --deep --strict` passed |
| `bash scripts/tests/check-bundled-helpers.sh` | Both editions' helper architecture/execution, real archive fixtures and corruption rejections passed |
| Publication audit | 580 candidate files and 33 app files passed the configured heuristic scan; this is not a security certification |

The native suite is included in `scripts/check-all.sh`; CI and release workflows compile it. Native execution remains a separate macOS desktop check, not an assertion made by `--build-only`.

## Reproduction and artifacts

```sh
bash scripts/tests/check-session-tabs.sh --build-only
bash scripts/tests/check-session-tabs.sh --run-only
bash scripts/tests/check-workflow.sh
bash scripts/build-app.sh
bash scripts/build-app.sh --edition base --output dist/editions/base/CrossDiff.app
codesign --verify --deep --strict dist/CrossDiff.app
codesign --verify --deep --strict dist/editions/base/CrossDiff.app
```

Logs use `.build/session-tabs-*.log`; the original failing baseline is `.build/session-tabs-baseline.log`, and the final 30-assertion run is `.build/session-tabs-final.log`. Full-window captures are in `.build-session-tab-checks/renders/`. These generated files stay ignored.

Input checks dispatch synthetic native events into the actual AppKit window, including the native knob tracking loop; physical mouse/trackpad hardware was not manually exercised. Application bundles are locally ad-hoc signed. No GitHub publication was performed for this change.

## Follow-up — build 36 click targets

The user reported an unresponsive first click with CrossDiff already in the foreground. A focused native harness containing the original session card and strip reproduced dead padding even without overflow: both clicks at the same coordinates failed. This identified incomplete hit areas rather than proving a timed first-event loss. The original plain selection button covered its content, while its surrounding padding belonged to the noninteractive container.

The fix moves padding into the selection button, gives it the full 29-point card height and an explicit rectangular content shape. Close has its own 24-by-29-point area. There is no parent click gesture that could also select a closed tab.

The first full-window diagnostic found nonresponsive points but used an accessibility group describing content rather than the whole visual card. The permanent regression now uses actual hosting-view bounds and the real Close accessibility button. Every selection case focuses the original session's native editor and verifies the application is active and the window is key before sending mouse-down/up through `NSWindow.sendEvent`.

- The original-component harness failed before the fix and passed afterward. Logs remain in `.build/tab-click-probe/`; throwaway source and executable were removed.
- `CROSSDIFF_TAB_CLICKS_ONLY=1 bash scripts/tests/check-session-tabs.sh --run-only` passed 9 assertions: title, icon, left/top/bottom padding, selection after scrolling, and active/inactive Close without affecting other sessions.
- The complete session-tab suite passed **39 assertions**, including existing scrolling, visibility and session-count regressions. Final light-hover and dark-narrow captures were visually reviewed.
- Full and Base were rebuilt as **0.15.0 build 36** and passed strict deep signature verification. Logs: `.build/session-tabs-click-build-*.log`, `.build/session-tabs-click-fixed.log` and `.build/session-tabs-click-regression.log`.

Events are synthesized. Holding the mouse down during an unrelated asynchronous refresh and first-click activation of a background window were not separately validated. The earlier full editing-workflow result belongs to build 35; this follow-up changes card hit areas and reruns the affected native tab suite.

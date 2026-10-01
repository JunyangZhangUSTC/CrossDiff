# 0.8.0 validation

Checked on macOS / Apple silicon for the Base and Full editions, official plugin installation and refreshed public documentation. All local test data, caches, logs and generated applications stayed inside the repository. Earlier feature-specific records remain available for the image, PDF, Hex, archive and new-comparison implementations.

## Completed locally

- `scripts/check.sh`: all core behavior checks passed, including 196 Unicode/newline fixture pairs, lossless merging, deletion projection, source-only copying, search/replacement, folder copying and persistence.
- Plugin regression scripts passed: 43 package/store checks; real helper and runner checks; HTTPS download checks; damaged-installation and manager-state recovery.
- `check-official-plugins.sh`: 41 offline transport checks passed. Coverage includes no requests while browsing, pinned repository URLs, complete-package size/SHA-256 checks, mismatched identity/version/runtime rejection, cancellation, automatic restricted installation, arbitrary-link review and Base → Full → Base preservation of external versions, disabled state and rollback history.
- `check-official-plugin-ui.sh`: 26 actual native UI checks passed. Eight complete-window captures cover Chinese/English, light/dark and 650/720-point widths. Text, cards and controls were visually reviewed.
- `check-plugin-workflow.sh`: actual local installation, enable/disable, removal/recovery, external JSON algorithm, native PDF pages/text, bilingual light/dark and narrow layouts passed; fixture source files remained unchanged.
- Python release safeguards: 19 tests passed, including refusal before mutation for draft asset conflicts and published releases, plus upload/read-back integrity. Seven inventory tests passed for deterministic packages, Base/Full contents and exact app/catalog/package correspondence.
- `scripts/render-readme.sh`: twelve real native screenshots generated from synthetic, path-free examples, covering text, deletion preview and the type chooser in both languages and themes. Hero artwork was regenerated from repository sources and visually checked.
- Both `scripts/build-app.sh` and `--edition base --output dist/editions/base/CrossDiff.app` completed. Both applications passed `codesign --verify --deep --strict`; signatures are ad-hoc, not Developer ID or notarization.
- Source/history and both application-bundle publication audits passed the configured sensitive-information patterns. This is a heuristic scan, not proof of the absence of all sensitive data. README asset/link checks and `git diff --check` passed.

## CI compatibility correction

The initial remote run on Swift 6.1.2 exposed a type-checker timeout in the image corner-resize calculation, which compiled on local Swift 6.3.3. The calculation was split into explicit Double displacement terms. All 569 image-rendering/geometry assertions passed after the change, and the native image workflow rebuilt successfully. Its additional live run exposed one right-top-corner drag that did not take effect; the other corner, rotation, reflection and source-preservation checks passed. A complete repeat passed, then a 40-drag targeted run produced one further missed resize at a different corner; all tested coordinates were within the handle. A second 40-drag run with event-delivery instrumentation passed. These observations do not distinguish a synthetic-event race from a product gesture defect; no speculative product change was made. The targeted suite now includes both top corners on both sides and configurable repetitions. This remains a preview validation limitation.

The next remote run passed the plugin/PDF and archive checks, including native-program compilation, then exposed another Swift 6.1.2 inference timeout in the binary test fixture's mixed arithmetic array literal. Its offsets now have an explicit Int array and a named block boundary; the fixture values are unchanged. All 479 binary core checks, eight detection scenarios and native binary-program compilation passed locally after the change. The final Actions result supplies remote compatibility evidence.

## Release verification

The release pipeline packages the exact clean tagged commit into Base and Full application ZIPs, official Archive/PDF packages, a separate JSON example, `plugins.json`, matching source, build information and SHA-256 checksums. Its upload job downloads every uploaded asset again and verifies its bytes before completing. Check the actual [Actions runs](https://github.com/JunyangZhangUSTC/CrossDiff/actions) for the final tagged commit; this source record does not claim a remote run that had not yet happened when written.

The workflow creates a draft pre-release. The version-pinned official plugin URLs become publicly downloadable only after that draft is published. Local transport tests do not prove public GitHub availability. Current official-catalog installation adds missing plugins; existing external packages can be updated through the reviewed file/HTTPS path. Bundled plugins update with the application.

## Remaining manual coverage

Intel builds, Apple notarization, Finder drag-and-drop and Gatekeeper first launch on a fresh machine remain unverified for this preview. Real input-method candidate windows, VoiceOver and extended everyday use still require manual evaluation. CI compiles native workflow programs with `--build-only`; local native runs above supply the interaction/rendering evidence.

# 0.7.0 validation — archive comparison

Environment: Apple silicon macOS, Swift 6.3.3 in Swift 5 language mode. All fixtures, caches, logs and native captures stay in project-local ignored `.build-*` / `.scratch/archive-m1` directories. No user archive, real session or clipboard is used.

This preview adds an official restricted archive plugin, host-owned bounded virtual catalogs, host result validation, archive/folder routing and a native directory tree. The earlier text, image, folder, Hex and PDF implementations remain intact.

## Reproducible checks

- `bash scripts/tests/check-archives-core.sh`: actual local-folder, ZIP and compressed TAR reads, known content hashes and failure boundaries.
- `bash scripts/tests/check-archive-plugin.sh`: deterministic packaging, manifest compatibility, actual JavaScript classifications, malformed inputs, directory aggregation, Unicode identities and 10,000-entry duplicate cohorts through the separate helper.
- `bash scripts/tests/check-archive-workflow.sh`: complete isolated native app, bundled capability and both archive/folder directions, model/result validation, source changes, cancellation, plugin enable/disable, saved path references and unchanged source fixtures. Includes real `NSOutlineView` expansion, filtering, content groups, selection and full-parent captures in Chinese/English, light/dark and 860-point windows.
- `bash scripts/check.sh`, plugin package/runtime/manager/PDF checks and binary core/detection checks: regression coverage of affected shared paths.
- `bash scripts/build-app.sh`, `codesign --verify --deep --strict dist/CrossDiff.app`, and `python3 scripts/audit-publication.py --app dist/CrossDiff.app`: final application delivery and public-bundle checks.

## Results

The local core regression, 43 plugin-package checks, plugin process/runtime checks, plugin management checks, 15 PDF algorithm checks, 28 PDF domain checks, binary core/detection checks and the complete native PDF/JSON plugin workflow passed. The archive reader passed **99 checks**, and the packaged archive algorithm passed **52 checks** through the real helper. The **final native archive workflow passed**, including production mode switching and full-parent captures. The review caught and fixed header overlap during mode changes and stale native labels after a language-only switch; both now have passing native regressions. Actual production screenshots were inspected in light/dark and English narrow layouts. The macOS `ditto` ZIP producer and system `tar` gzip producer were also checked against synthetic Chinese-named files and passed.

The final **0.7.0 (15)** application built successfully, passed `codesign --verify --deep --strict`, and passed the configured publication audit (215 candidate source files and 9 app files). This audit is heuristic, not a general absence-of-secrets proof. Output: `dist/CrossDiff.app`; detailed local logs are in `.scratch/archive-m1/`. No release or remote CI run is claimed.

The native tree benchmark used 10,000 entries with all implicit parents inside the budget. At 128 levels, the optimized tree build took approximately 38 ms on the local machine; this is an observation rather than a cross-machine performance guarantee.

## Scope of evidence

Native workflow checks must run with a working macOS application session; `--build-only` only compiles them. CI compiles native workflows and runs headless reader/algorithm suites; it does not certify native-window appearance. Local screenshots inspect the real parent view, not a web mockup.

Reader checks establish the documented supported subset, not compatibility with every archive implementation. Metadata checks detect ordinary source changes and replacements, not an immutable filesystem snapshot. Comparison is content-oriented and does not compare timestamps, permissions, xattrs or resource forks as metadata. Ordinary archive entries containing those bytes are still compared.

Intel, physical macOS 14, every third-party archive producer, VoiceOver end-to-end interaction and Finder's graphical file chooser remain manual verification areas. The application is ad-hoc signed, without Developer ID signing or notarization. No GitHub release is published by these checks.

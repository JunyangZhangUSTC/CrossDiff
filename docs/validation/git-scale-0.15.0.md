# Git scan scale and chooser placement — 0.15.0 build 33

Date: 2026-10-05. Validation on Apple silicon macOS. All fixtures, caches, captures and application bundles remained inside this checkout. Source repositories were synthetic. This record supersedes the scan limits recorded for build 32; it does not change the historical checks in that record.

## Changes

- Git appears immediately after Text in the first row of New Comparison. Other types retain their relative order. Disabled or removed bundled Git stays hidden and returns to its priority position when restored.
- Repository scans no longer have the former 256 MiB-per-file, 1 GiB-total, 50,000-file or total-scan-time ceiling. Git catalogs stream records; working files hash in chunks; sorting, hashing and verification remain cancellable.
- The restricted Git plugin receives up to 128 complete file pairs per invocation. Global coverage, indivisible renames and per-batch identities are checked before the complete result is published. General helper limits are unchanged. No full-repository JSON payload is built.
- The status bar reports actual working bytes/files and batch validation counts. Updates are throttled before dispatch to the main actor and guarded against cancellation or a newer operation.

## Completed checks

| Check | Result |
| --- | --- |
| `CROSSDIFF_GIT_NETWORK_CHECK=1 bash scripts/tests/check-git-core.sh` | 130 checks passed, including 123 offline checks and 7 real HTTPS/cache checks |
| `bash scripts/tests/check-git-plugin.sh` | 112 protocol checks and 19 production-adapter batch checks passed |
| `bash scripts/tests/check-new-comparison-workflow.sh` | 138 native assertions passed; actual Chinese/English light/dark and narrow chooser windows captured and visually reviewed |
| `bash scripts/tests/check-git-workflow.sh` | 39 native checks passed: commits, local source presets, file detail, read-only commands, language and window layouts |
| `bash scripts/check.sh` | Existing core regression passed |
| Plugin inventory tests | 10 passed |
| Full and Base application builds | 0.15.0 build 33; strict deep ad-hoc signature verification passed |
| `bash scripts/tests/check-bundled-helpers.sh` | Both edition inventories, helper architectures/execution and archive corruption regressions passed |
| Publication audit and `git diff --check` | Passed; the publication audit is heuristic, not a security certification |

### Scale evidence

- Two sparse files of roughly 600 MiB each were actually read through **1,258,291,248 bytes (1.17 GiB)**. Complete raw blob digests matched native Git, including final bytes; no Git objects were written by capture. Sparse allocation avoided spending that much physical disk space, not the content-reading work.
- A second scan was cancelled after **314,572,800 bytes (300 MiB)** had been read, before completing its first file.
- **70,001 entries** with **17,220,246 raw pathname bytes** passed committed-tree, index, working-candidate and raw-diff enumeration. This exceeds both the old count and stdout-buffer ceilings. The catalog fixture took approximately 21.46 seconds in this run; timing is diagnostic, not a performance guarantee.
- **50,513 synthetic file pairs** completed **395 real restricted helper invocations** in approximately 39.63 seconds, retaining exact coverage, native order, counts and cross-boundary renames. Tests also cover maximally escaped 4096-byte paths, empty input through the real helper, later-batch failure and cancellation.
- Sorting cancellation was checked at the 1024-comparison interval. No incomplete result is published as successful after cancellation.

## Artifacts and remaining boundaries

The Full application is `dist/CrossDiff.app`; Base is `dist/editions/base/CrossDiff.app`. Both contain byte-identical Git packages matching `dist/Plugins/Git.crossdiffplugin`. Local build logs use `.build/git-scale-*.log`; core scan evidence is in `.build-git-core-checks/unlimited-scan-final.log`. Captures are in `.build-new-comparison-workflow/renders/` and `.build-git-workflow/renders/`. These generated files remain ignored.

The release compiler emitted module-cache/debug-information warnings already seen in earlier builds; compilation, linking, runtime regressions and signature checks succeeded. No new source diagnostics were reported.

Removal of scan ceilings does not imply constant metadata memory or guaranteed performance for arbitrarily large repositories. File-detail preview remains 2 MiB per side; binary detail shows at most 64 KiB. Remote download/cache limits and the 1,000-candidate exhaustive rename heuristic are unchanged and documented in the usage guide. The applications are locally ad-hoc signed, not notarized. No GitHub publication was performed by this task.

## Follow-up — build 34 chooser order

The user finalized the leading order as **Text, Folders, Images, Git, Binary, Archives**, followed by the other available plugins in their existing relative order. This supersedes build 33's first-row Git placement. Disabled or removed plugins remain absent.

The existing native creation suite passed all 138 assertions after updating the expected order. Chinese/English light/dark and narrow captures were visually reviewed, with Git next to Images in the second row. Full and Base were rebuilt as 0.15.0 build 34, both passed strict deep signature verification and bundled-helper checks. Logs use `.build/chooser-order-*.log`; the chooser captures above now show this final order. Scan and plugin-engine behavior was unchanged by this layout follow-up.

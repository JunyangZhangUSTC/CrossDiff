# Office 0.12.0 validation

Date: 2026-10-02. Local Apple silicon/macOS development environment; Swift 6.3.3 in Swift 5 language mode. This records local behavior and app verification, not a GitHub CI result or published release.

## Completed checks

| Check | Observed result |
| --- | --- |
| `check-office-import.sh` | 61 passed: DOCX/XLSX/PPTX, source order, text/Unicode, tables/revisions/notes, formulas/caches/shared formulas, Strict namespaces and UTF-16, resource limits, cancellation, external relationships, hostile ZIP/XML, duplicate coordinates/containers and MCE compatibility alternatives. |
| `check-office-plugin.sh` | 34 passed: real restricted helper, cross-row exact matches, composite keys, empty/duplicate keys, multiplicity, 4,000 reordered rows, insertions versus movement, formula/value types, Unicode, source coverage and forged-result rejection. |
| `check-office-model.sh` | 16 passed: immutable imported snapshots, explicit reload, independent section selection, session round trip, filtering without re-execution, cancelled providers joined serially, stale results blocked, empty workbook and family mismatch. |
| `check-office-workflow.sh` | Full native workflow passed, after rebuilding current sources. Modern-format creation, mixed-family rejection, legacy conversion guidance, actual key-selection controls, search, changed-record details, formulas, section navigation, persistence, read-only source hashes, original preview, Base package installation, and light/dark/narrow windows. |
| `check-archives-core.sh` | 99 passed after reusing the ZIP reader for Office. |
| `scripts/check.sh` | All existing core behavior checks passed. |
| Plugin regression checks | Core 43, runtime 16, official catalog/install 41, manager checks and inventory unit tests (7) passed. |
| Application | `build-app.sh` built Full 0.12.0 (21); `codesign --verify --deep --strict dist/CrossDiff.app` passed. Office 0.1.0 is bundled; independent package generated under `dist/Plugins/`. |

The native check first timed out inside the tool sandbox because macOS application services were inaccessible. It was then run with native service access against isolated, newly generated project-local sessions and fixtures. That run passed; the timeout is not counted as a pass. An early native PPT fixture had malformed XML and was corrected before the successful run.

Actual parent-window captures were inspected at 1220×790 and 860×620 content sizes, in both themes. Excel source row numbers, cell colors and keys were visible; Word/PPT inline character differences remained readable; generated Word section titles switched languages while user sheet names stayed unchanged. Quick Look rendered the synthetic DOCX original successfully. Generated captures remain in the ignored `.build-office-workflow/renders/` directory.

## Review findings resolved

Standards review identified heavy input construction/result decoding on the main actor. They now run in a cancellable detached worker; only state publication stays on the main actor. Model checks passed afterward.

Spec review found that OOXML compatibility branches could duplicate content. Word/PPT Choice/Fallback fixtures first reproduced the bug, then passed after selecting the single stored fallback with explicit scope diagnostics. A file with no supported fallback now fails clearly. Position-only matches no longer claim identity or movement; only exact/key matches contribute to the relative-order backbone.

## Limits and outstanding coverage

This is a bounded content comparison, not a complete Office rendering or editing engine. Formatting, charts, images, animations, macros and embedded objects are not fully compared; legacy/encrypted formats are unsupported. Formula results are preserved caches, not recalculated values. Shared-formula followers retain their group/master records. Dates retain numeric/date records and format metadata.

Coverage uses deterministic synthetic packages and the macOS preview service. Large diverse files saved by multiple Office versions, unusual compatibility extensions, complete visual fidelity, Intel hardware, Developer ID/notarization and remote CI for this commit remain unverified. Quick Look support and appearance depend on macOS; only the DOCX original preview was visually exercised in this run. Source files remained byte-identical.

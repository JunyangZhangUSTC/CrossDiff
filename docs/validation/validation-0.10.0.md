# 0.10.0 API comparison validation

Checked on 2026-10-02, macOS 26.6.2, Apple silicon, Swift 6.3.3. All sources, fixtures, sessions, logs, screenshots, packages and applications remained inside the repository. Synthetic HTTP records were used; no HTTP request, cURL command or user credential was sent or executed. This is a local source preview, not a published release or a claim of testing on all supported systems.

## API behavior

- `check-api-import.sh`: **94 checks passed**. HTTP request/response and paired framing; HAR records, base64 UTF-8 and unavailable bodies; cURL quoted arguments, external-file/shell rejection, literal versus URL globbing and IPv6; exact JSON numbers, Unicode keys, arrays, missing/null, repeated headers/parameters; cancellation, ordinary-file descriptors, symlink/UTF-8/size limits and source preservation.
- Three nearly 4 MiB inputs with dense query separators, short HTTP headers and short cURL tokens were rejected before large field arrays were created, in 0.851 seconds combined on this machine. Exactly 5,000 total fields are accepted; 5,001 are rejected.
- `check-api-plugin.sh`: **31 checks passed**, including actual packaged JavaScript in the restricted helper process, normalized HTTP/cURL inputs, exact numeric/Unicode differences, repeated fields, explicit subtree/header rules, unknown body propagation, partial output, package integrity, independent installation and saved state. `completed` means the algorithm completed; unknown fields remain explicitly unknown. `partial` identifies truncated output.
- `check-api-workflow.sh`: passed using a full native window, real restricted plugin and isolated sessions. Paste/file creation, HTTP/cURL/HAR, independent HAR choices, search, hidden values not searchable, explicit source reveal, ignored fields/clear/subtree rules, Unicode-distinct source and rule changes, reload, tab state, persistence, cancellation/stale results and Base installation were exercised.
- Native API views and ignore-rule popovers were inspected in Chinese/English, light/dark and 860×580 windows. Captures remain in `.build-api-workflow/renders/`. A material-backed popover initially rendered pink in offscreen captures; an explicit theme background corrected the actual rendered surface.

## Reviews and regressions

Independent Spec and Standards reviews found and led to fixes for explicit TXT/JSON selection, Swift canonical-equivalence collapsing distinct JSON keys/values/rules/source identities, trailing whitespace lost in paired HTTP framing, and cURL URL globbing. Dense-input allocation bounds were additionally reviewed and strengthened. No remaining blocking review findings were reported.

Existing core checks passed, including 196 Unicode/newline fixture pairs, merge/deletion/search/replacement/folder/storage behaviors. Plugin core (43), archives (52), official catalog/installation (41), plugin runtime/download/manager, PDF, binary and image checks passed. The release/inventory Python suites passed **19 + 7 tests**. The existing image engine passed 569 assertions; Photography plugin passed 35, metadata checks passed, and the deterministic photo engine passed 28 with macOS service access.

The existing new-comparison native workflow passed **123 assertions**. Existing plugin windows passed PDF pages/text, external JSON execution, lifecycle/recovery, themes and immutable-source checks. Official plugin windows passed with four catalog entries.

The original full text workflow once timed out at command-Z. The same binary passed the entire workflow on one repeat using a fresh repository-local session directory: undo/redo, find/replace, search-field undo, settings focus isolation, language changes, toolbar actions and rendering. No product code or assertions were changed to obtain that result; the initial failure was not conclusively diagnosed. Repeat results are in `.build-workflow-checks/api-diagnostic-renders/`.

## Full-suite limits

`check-all.sh` was attempted, but it is **not reported as fully passing**. In the restricted execution environment it stopped at the existing photography engine's image decode. That exact engine suite passed 28 checks when repeated with access to macOS image services. The old standalone `check-editor.sh` also has an incomplete explicit source list: it cannot resolve existing `ImageComparisonModel`, `ArchiveComparisonModel`, `PluginManager` and other workspace dependencies. It was not rewritten as part of this API feature. Full-window editor behavior is covered by the successful integrated workflow above. Remaining standalone scripts after that point were not all rerun.

## Delivery

Full and Base applications are version **0.10.0 / build 19**, with API **0.1.0** independently packaged. Full contains Archive, PDF, Photography and API; Base contains Archive. The API standalone package, bundled Full package and generated release asset are byte-identical, and both offline catalogs contain the matching digest/version. All comparison content remains local.

Both application builds passed `codesign --verify --deep --strict` and publication audits over source/history/bundles. The audit is heuristic and its detection rules were not changed; credential-masking tests use synthetic placeholder identities on a reserved test domain. Local builds are ad-hoc signed, not Developer ID signed or notarized.

No GitHub release/upload, global installation or Applications installation was performed. Older published hosts do not support the new HTTP input kind; use the matching 0.10.0 build. Intel, macOS 14/15 runtime behavior, complete cURL syntax, every HAR exporter and extended everyday/VoiceOver use remain outside this validation.

# Plugin development · Experimental v1

Status: 2026-10-04, for the unpublished CrossDiff 0.14.0 source preview (Photography/API/Audio/Office/Video 0.1.0 and PDF 0.2.0). The protocol, package format and host views are experimental. This describes the current implementation, without promising migration-free compatibility. [简体中文](development.md)

The contract is implemented in [PluginProtocol.swift](../../Sources/CrossDiffCore/PluginProtocol.swift), [PluginPackage.swift](../../Sources/CrossDiffCore/PluginPackage.swift), [PluginStore.swift](../../Sources/CrossDiffCore/PluginStore.swift) and [PluginRunner.swift](../../Sources/CrossDiff/PluginRunner.swift). Future capabilities discussed in the [architecture design](../architecture/compare-everything.md) are not automatically available in this preview.

## 1. Available capabilities

Plugins supply comparison algorithms. The host reads inputs, runs tasks and displays results.

| Input kind | Data supplied by the host | Result view |
| --- | --- | --- |
| `text` | Decoded text `{text: "…"}` | `table`: a read-only results table |
| `pdf` | Page text, dimensions and preview fingerprints | `documentPages`: native PDF pages and text differences; `table` is also accepted |
| `archiveCatalog` | Virtual paths, kinds, sizes, full content digests and verification states from an archive or local folder | `archiveTree`: a read-only directory tree and content groups across paths |
| `httpExchange` | Bounded HTTP/cURL/HAR records normalized to typed sections and fields | `apiExchange`: paired request/response field differences |
| `photoAnalysis` | Bounded, normalized Apple/OpenCV RGB/HSL distributions, neutral share and analysis metadata | `photography`: paired photos, regions, histograms, recorded curves and capture information |
| `audioAnalysis` | Bounded source metadata and host matching evidence; no PCM, waveform or spectral grids | `audioTimeline`: paired timelines, channel waveforms, spectrograms, regions and A/B audition |
| `officeDocument` | One selected DOCX/XLSX/PPTX section with typed cells, original positions, formulas and saved values | `officeDocuments`: native grids and paragraph/slide content |
| `videoAnalysis` | Bounded video metadata, without paths, frame pixels, PCM or correspondence claims | `videoTimeline`: native paired pictures and timelines, manual timing and paused inspection |

The bundled [PDF plugin](../../Plugins/PDF/) contains the JavaScript algorithm that aligns and classifies pages. PDFKit extracts and presents them in the host. The independently installable [JSON example](../../Plugins/Examples/JSON/) compares top-level JSON values through the same contract.

The application currently starts only `pairwise` tasks. Public types distinguish `threeWayMerge` and `multiSubject` and validate their roles, but this release provides no corresponding UI or algorithms. Do not advertise unsupported modes or silently compare only the first two inputs.

Custom native views, arbitrary schema renderers, artifact/resource handles, companion libraries, plugin dependencies, remote sources, plugin exports and write-back are deferred. Existing text, folder, image and binary Hex comparisons remain host features.

## 2. Start with the example

Run in Bash from the repository root. Development inputs, outputs and caches remain inside the repository:

```sh
source scripts/project-env.sh
python3 scripts/package-plugin.py Plugins/Examples/JSON --output dist/Plugins/JSON.crossdiffplugin
```

Choose **Install from File…** in plugin management, or drop the generated file into CrossDiff. Review its name, version, identifier and runtime before installing. Select the JSON plugin from the Compare menu and open two files. Ordinary `.json` files still open with the existing text comparison by default; the example also declares `.cdjson`.

The bundled PDF package has a reproducible packaging entry point:

```sh
source scripts/project-env.sh
python3 scripts/package-pdf-plugin.py --output dist/Plugins/PDF.crossdiffplugin
```

The Full edition bundles `org.crossdiff.pdf`; Base can install it separately from the official catalog. An external package cannot replace an ID bundled in the running edition. For a custom PDF experiment, create a source directory inside the repository and use your own ID. Packaging does not replace validation at installation.

Package the official Archive algorithm with:

```sh
source scripts/project-env.sh
python3 scripts/package-archive-plugin.py --output dist/Plugins/Archive.crossdiffplugin
```

The script in [Archive sources](../../Plugins/Official/Archive/) computes path classifications, directory states and content groups. `org.crossdiff.archive` is also a reserved bundled ID. Third-party algorithms use their own IDs and can reuse the same restricted runtime and native directory view. Ordinary ZIP/TAR files are comparison sources; only `.crossdiffplugin` files are installation packages.

Photography uses the normal package installation and restricted execution flow:

```sh
source scripts/project-env.sh
python3 scripts/package-photography-plugin.py --output dist/Plugins/Photography.crossdiffplugin
```

The [Photography algorithm](../../Plugins/Official/Photography/) derives bilingual comparisons from host-provided statistics. OpenCV is a fixed capability of the matching Base/Full host, not native code installed from the plugin package. Full bundles `org.crossdiff.photography`; Base can install it separately. Other plugin IDs can use the same contract without an official-ID execution branch. The 0.8.0 host does not understand this input kind; use the current 0.11.0 host during development. Photography support began in 0.9.0. Catalog URLs for an unpublished version are not yet downloadable assets.

Package the official API algorithm with:

```sh
source scripts/project-env.sh
python3 scripts/package-api-plugin.py --output dist/plugins/CrossDiff-Plugin-API-0.1.0.crossdiffplugin
```

Full bundles `org.crossdiff.api`; Base can install it independently. It requires the HTTP host capability introduced in 0.10.0; protocol v1 alone does not make older hosts understand new input kinds. Local API imports are parsed, never executed or fetched. See the [API sources](../../Plugins/Official/API/) and [scope](../architecture/api-comparison.md).

Package Audio through the same restricted installation flow:

```sh
source scripts/project-env.sh
python3 scripts/package-audio-plugin.py --output dist/Plugins/Audio.crossdiffplugin
```

Full bundles `org.crossdiff.audio`; a matching Base host can install the standalone package. Audio analysis and the Olaf fingerprint helper are 0.11.0 host capabilities. The plugin summarizes host metadata and evidence; it contains no native libraries and cannot replace the host DSP or fingerprint implementation. See the [Audio sources](../../Plugins/Official/Audio/) and the audio contract below.

## 3. A package is one JSON file

A `.crossdiffplugin` is a bounded UTF-8 JSON file, **not a directory or ZIP archive**. There are no install scripts, archive paths, resource lists or native companion libraries.

| Field | Rule |
| --- | --- |
| `formatVersion` | Integer `1` |
| `manifest` | The manifest object below |
| `script` | A nonempty JavaScript string for `restrictedJavaScript` |
| `executable` | Nonempty executable bytes, encoded as a JSON base64 string, for `trustedExecutable` |
| `sha256` | SHA-256 of the raw payload bytes, as 64 lowercase hexadecimal digits |

Exactly one of `script` and `executable` must be present, matching the runtime. A script digest covers the string's UTF-8 bytes, not the package or escaped JSON representation. A native digest covers the complete base64-decoded executable. Sign native code **before** packaging and hashing: signing changes its bytes.

The package limit is **16 MiB**, the script limit **2 MiB**, and the executable limit **8 MiB**. Local loading rejects directories, a symbolic link at the final path, and oversized files. A matching digest verifies the payload against the package declaration; it does not authenticate the author. Installation displays the publisher as unverified.

Example manifest:

```json
{
  "id": "example.crossdiff.json-keys",
  "version": "0.1.0",
  "name": {"zhHans": "JSON 键值比较", "en": "JSON Key Comparison"},
  "summary": {"zhHans": "按顶层键比较 JSON 值。", "en": "Compare JSON values by top-level key."},
  "runtime": "restrictedJavaScript",
  "inputKind": "text",
  "fileExtensions": ["json", "cdjson"],
  "resultView": "table",
  "supportedModes": ["pairwise"],
  "minHostProtocol": 1,
  "maxHostProtocol": 1
}
```

Use these camelCase field names exactly, including `zhHans` and `en`. IDs are at most 128 UTF-8 bytes, begin with a lowercase English letter, and contain lowercase letters and digits in segments separated by `.` or `-`. Versions use three numeric components with optional prerelease/build suffixes, up to 64 bytes. Each localized name is nonempty and at most 512 bytes; each summary is nonempty and at most 4096 bytes.

`fileExtensions` contains 1–32 unique lowercase extensions without a leading dot. Each is at most 16 bytes and may contain letters, digits, `_` and `-`. `supportedModes` must be nonempty and unique. The host protocol range must include `1`. `documentPages` requires `pdf` input. `archiveCatalog` and `archiveTree` must be paired, with `supportedModes: ["pairwise"]`; archive input cannot use `table`. `photoAnalysis` likewise requires `photography` with `supportedModes: ["pairwise"]` and cannot use `table`. The host supplies its reserved identifier list explicitly; an official-looking name does not grant official status.

## 4. Requests and the JavaScript entry point

Define a synchronous function:

```javascript
function compare(request) {
  const left = request.inputs.find(input => input.role === "left").content.text;
  const right = request.inputs.find(input => input.role === "right").content.text;
  const equal = left === right;
  return {
    protocolVersion: 1,
    runID: request.runID,
    schema: "crossdiff.table/1",
    status: "completed",
    summary: {zhHans: equal ? "文字相同" : "文字不同", en: equal ? "Text matches" : "Text differs"},
    diagnostics: [],
    payload: {rows: [{label: "Text / 文字", left: left, right: right, state: equal ? "same" : "changed"}]}
  };
}
```

This minimal example is suitable for short text only. A full long document cannot be placed in one table cell. Production plugins should split results into meaningful rows, respect the limits below, and use `partial` with bilingual diagnostics when appropriate.

Request structure:

```json
{
  "protocolVersion": 1,
  "runID": "host-generated-run-id",
  "mode": "pairwise",
  "inputs": [
    {"id": "left", "role": "left", "name": "a.txt", "content": {"text": "甲"}},
    {"id": "right", "role": "right", "name": "b.txt", "content": {"text": "乙"}}
  ],
  "options": {}
}
```

Use input roles rather than array order. Input IDs must be unique; return `runID` unchanged.

| Mode | Required roles | Application support |
| --- | --- | --- |
| `pairwise` | Exactly `left` and `right` | Implemented |
| `threeWayMerge` | Exactly `base`, `ours` and `theirs` | Contract validation only |
| `multiSubject` | 3–32 `peer` inputs with unique IDs | Contract validation only |

JSON values are objects, arrays, strings, finite numbers, booleans and null. Swift uses `PluginJSONValue` with typed accessors and string/integer subscripts. A missing key is distinct from `.null`. Numbers use Double/JavaScript Number; domain contracts should use strings when exact large integers are required.

Text plugins accept regular files up to 2 MiB per side, with at most 4 MiB of decoded UTF-8 text per side. The encoded request is limited to 16 MiB. Inputs do not contain arbitrary file handles, credentials or filesystem APIs.

## 5. Result schemas

Every result includes `protocolVersion`, `runID`, `schema`, `status`, `summary`, `diagnostics` and `payload`. Status is `completed` or `partial`. Exceptions, process failure, cancellation, timeout and protocol errors are handled as failures, not as successful empty results.

The bilingual summary allows 16 KiB per language. There may be up to 128 bilingual diagnostics, each nonempty and at most 4096 bytes per language. Payload must be an object; the complete encoded result is limited to 8 MiB. The host validates protocol, run ID and the schema corresponding to the declared view, and discards obsolete task output.

### `crossdiff.table/1`

Use `resultView: "table"` and this payload:

```json
{"rows": [{"label": "name", "left": "old", "right": "new", "state": "changed"}]}
```

There may be up to 10,000 rows. `label`, `left` and `right` are strings, each at most 32,768 UTF-8 bytes. State is `same`, `changed`, `added`, `removed` or `unknown`. Cells are plain text, not HTML, native view declarations or executable code. The host handles colors, filtering, selection and localized UI.

The JSON example compares parsed values, ignoring whitespace and object-key order; it does not preserve duplicate-key semantics. It bounds key count, nesting and numeric precision. It is not a raw JSON byte-equality check.

### `crossdiff.document-pages/1`

Use `inputKind: "pdf"` and `resultView: "documentPages"`. Each input content has this shape:

```json
{
  "pages": [{"index": 0, "text": "Page text", "width": 595, "height": 842,
             "fingerprint": "host-generated-sha256", "textTruncated": false}],
  "truncated": false
}
```

Page indices are zero-based and dimensions use PDF points. The host reads at most 48 MiB per PDF, extracts the first 200 pages, and limits text to 32,768 UTF-16 code units per page and 262,144 per document. Fingerprints come from previews with a maximum edge of 384 pixels. Original PDF data stays in the host and is not sent as base64 to the script.

Example result payload:

```json
{"pairs": [
  {"left": 0, "right": 0, "kind": "same"},
  {"left": null, "right": 1, "kind": "added"},
  {"left": 1, "right": 2, "kind": "changed"}
]}
```

Kind is `same`, `changed`, `added`, `removed` or `unknown`. Added pages have only a right index; removed pages have only a left index. Other kinds require both indices. Indices must refer to extracted pages, and every extracted page on each side must appear exactly once. The host validates mappings before rendering.

Starting with host 0.12.2 and PDF plugin 0.2.0, payload may also contain `"alignment": {"strategy": "smart", "reliablePairs": 2}`, or `"alignment": {"strategy": "pageNumber", "reason": "insufficientEvidence", "reliablePairs": 0}`. Fallback reasons are `insufficientEvidence` and `ambiguousEvidence`; `smart` has no fallback reason. `reliablePairs` counts reliable ordered anchors, not confidence in every displayed pair, and must not exceed the number of two-sided pairs. Legacy plugins without this metadata remain usable by page number or manual selection; the new host falls back conservatively in Smart Match. Older hosts can read the original `pairs` but do not gain the new controls.

The host defaults to original page order and also offers smart matching and independent manual page selection. PDF 0.2.0 finds consistent ordered anchors using unique previews or informative text. Multi-page inputs require at least two anchors covering half of the shorter document. A single low-information page cannot shift based only on its preview fingerprint; short headings, repeated or truncated text are insufficient text evidence. Insufficient evidence falls back to page order. Gaps without decisive correspondence between anchors are compared in relative order and require review. A one-sided page is not necessarily a version insertion or deletion.

`same` means the text and preview representations match, not PDF byte identity or full-resolution visual identity. Scanned or blank pages may have no extractable text; OCR and semantic analysis are not included. Truncated or copy-restricted extraction retains its limitations. Locked, corrupt or empty documents fail explicitly. Password entry and PDF write-back are unsupported. See [the decoder and limits](../../Sources/CrossDiff/PDFComparisonDocument.swift).

### `crossdiff.archive-tree/1`

Declare `inputKind: "archiveCatalog"`, `resultView: "archiveTree"` and `supportedModes: ["pairwise"]`. The host streams the user-selected archive or folder and hashes complete regular-file contents with SHA-256. The plugin receives only this content, without source absolute paths, file handles, original file bytes or read callbacks:

```json
{
  "listingComplete": true,
  "entries": [
    {"id":"docs","path":"docs","kind":"directory","size":0,"sha256":null,"contentState":"verified"},
    {"id":"docs/a.txt","path":"docs/a.txt","kind":"file","size":3,"sha256":"<64 lowercase hex>","contentState":"verified"},
    {"id":"link","path":"link","kind":"symbolicLink","size":null,"sha256":null,"contentState":"unverified"}
  ]
}
```

Each side has at most 10,000 entries, including implicit ancestor directories supplied by the host. `id == path`: a normalized relative virtual path, at most 4096 UTF-8 bytes and 128 components. Absolute paths, empty components, `.`, `..`, NUL, backslashes and Windows drive prefixes are rejected. Paths are case-sensitive and preserve their Unicode spelling. The host rejects canonically equivalent duplicate paths on one side; the algorithm uses NFC internal keys to match sides while returning original IDs. A virtual path is display/reference data, never permission to read a local file.

Kind is `file`, `directory`, `symbolicLink`, `hardLink` or `other`. Size is a nonnegative safe integer or null. Verified regular files require size and a 64-digit lowercase SHA-256 of their complete contents. Directories have size=0 and sha256=null. Links and special entries remain unverified and cannot enter content groups. Current scans succeed only after complete enumeration, so `listingComplete` is true; unverified contents may still produce a partial result. See [formats, read-only behavior and limits](../usage.md#archives).

Result payload:

```json
{
  "pairs": [
    {"left":"docs","right":"docs","state":"changed"},
    {"left":"docs/a.txt","right":null,"state":"removed"},
    {"left":null,"right":"renamed.txt","state":"added"}
  ],
  "sameContentGroups": [{"left":["docs/a.txt"],"right":["renamed.txt"]}]
}
```

Each input entry appears exactly once on its side. Non-null pairs must share a path; both sides cannot be null. Classification priority is: any present unverified entry → `unknown`; otherwise a missing side → `removed`/`added`; different kinds → `typeChanged`; verified regular files compare size + SHA-256 for `same`/`changed`. Matching directories start as same, then aggregate children deepest first: any unknown child makes the parent unknown; otherwise any non-same child makes it changed. Two empty directories remain same. If an incomplete listing is supplied, missing paths on that side cannot establish definite additions or removals.

`sameContentGroups` contains complete cohorts of verified regular files sharing size + SHA-256. Both sides must be nonempty and the union must contain at least two distinct paths. Return side-specific ID lists without a Cartesian product. A same-path-only pair is not a content group. Groups show identical content, without asserting a unique rename or move. The host independently validates coverage, classification, directory aggregation and complete cohorts against the current catalogs before rendering; unknown rows require partial status. Compression methods, timestamps and permission metadata do not participate in content equality.

### `crossdiff.photography/1`

Declare `inputKind: "photoAnalysis"`, `resultView: "photography"` and `supportedModes: ["pairwise"]`. The host reads user-authorized photographs using Apple color management/RAW decoding and OpenCV 4.12.0 conversion/statistics on background tasks. Each input `content` has this shape (arrays are abbreviated; valid requests require the lengths below):

```json
{
  "red": [], "green": [], "blue": [], "lightness": [], "hue": [], "saturation": [],
  "neutralFraction": 0.25,
  "analyzedPixels": 4096,
  "sampled": false,
  "analysisSpace": "sRGB · SDR [0, 1] · HSL lightness · OpenCV 4.12.0"
}
```

| Field | Meaning and validation |
| --- | --- |
| `red`, `green`, `blue`, `lightness`, `saturation` | 256 finite bins each, values in 0–1, each array summing to 1 within `0.0001`; L means HSL lightness, not physical luminance |
| `hue` | 360 bins over 0–360°, finite values in 0–1 divided by all valid pixels; sum is `1 - neutralFraction` within the same tolerance |
| `neutralFraction` | Finite 0–1 share with HSL S < 0.02; these pixels are excluded from hue bins |
| `analyzedPixels` | Integer 1–100,000,000; current host samples have at most a 4096 px longest edge; this counts valid samples, not necessarily source pixels |
| `sampled` | Boolean, true when the source region is resampled for the size budget |
| `analysisSpace` | Nonempty, up to 1024 UTF-8 bytes, identical on both sides; respect its color-space and range semantics |

Statistics use color-managed floating-point sRGB SDR, clamped to 0–1. Fully transparent/non-finite samples are excluded; other valid samples receive equal weight. OpenCV `cvtColor(COLOR_RGB2HLS)` returns H, L, S channels; `calcHist` produces the distributions. Hue excludes near-neutral pixels and must not be renormalized to 1. Identical distributions do not establish identical pixels or photographic quality.

Photo pixels, absolute paths, EXIF and XMP stay in the host; scripts receive none of these or read callbacks. Input `name` still contains the filename. Changing regions starts a new task, with cancellation and stale-result protection. The host persists named pairs and selected XMP paths. Third-party plugins can interpret the supplied distributions, but cannot load custom native dependencies or add arbitrary chart types through JSON.

Return schema `crossdiff.photography/1` with this payload:

```json
{"findings": [{"zhHans": "右侧低明度区域占比更高。", "en": "The right region has a higher low-lightness share."}]}
```

`findings` contains 0–8 entries, each with nonempty `zhHans` and `en` strings of at most 2048 UTF-8 bytes. The host shows the first three by default and the remainder under analysis information. Standard `summary`, `diagnostics` and `status` validation still applies. Charts use host statistics directly. Apple ImageIO reads actual Adobe CRS curve control points, with illustrative connecting lines rather than reproduced rendering. Do not claim to infer shutter speed, Kelvin temperature, exposure adjustments or the creator’s HSL/curve slider settings from rendered images.

Each source is limited to 256 MiB/64 megapixels, display previews to a 2048 px longest edge, and ROI statistics to 4096 px. RAW support depends on the OS, camera and encoding; embedded previews never substitute for full decoding. XMP is limited to 8 MiB and sidecars require explicit selection rather than automatic adjacent-file access. See the [photography design](../architecture/photography-comparison.md).

### `crossdiff.api-exchange/1`

Declare `inputKind: "httpExchange"`, `resultView: "apiExchange"` and `supportedModes: ["pairwise"]`. The host parses one selected record per side, including when the source contains multiple HAR entries. `content` has `sections` and bilingual `diagnostics`. Allowed section IDs: `request.summary`, `request.query`, `request.headers`, `request.body`, `response.summary`, `response.headers`, `response.body`.

```json
{
  "sections": [{"id": "response.body", "label": {"zhHans": "响应正文", "en": "Response body"},
    "fields": [
      {"key": "$state", "label": "Body availability", "type": "bodyState", "value": "json", "sensitive": false},
      {"key": "", "label": "$", "type": "object", "value": "", "sensitive": false},
      {"key": "/count", "label": "/count", "type": "number", "value": "9007199254740993", "sensitive": false}
    ]}],
  "diagnostics": []
}
```

Fields have unique keys within their section. Header/query keys are `/escaped-name/occurrence` with zero-based occurrence; header names are ASCII-lowercased, query names retain spelling and encoding. Optional `name` retains the original name. Body JSON paths use RFC 6901, including the empty root path. Container fields have empty values and `object`/`array` types, not child counts. JSON numbers are strings in this contract to avoid wire-number rounding. Other leaf types are `string`, `bool` and `null`. `$state` is a `bodyState` marker (`json`, `text`, `empty`, `missing`, `unsupported`); `$text` carries a `text` body. An absent body is not equal to an empty body.

Options `ignoreHeaders` and `ignoreJSONPointers` are string arrays (at most 128 each), default empty. Header matching is case-insensitive; JSON pointers match a node and its descendants in request and response bodies. Ignore markers neither remove rows nor hide unknown body availability. Each selected record has at most 5,000 fields; values are at most 1 MiB, keys/labels at most 16 KiB. Source parsing has additional bounds in the [usage guide](../usage.md#api).

Payload is `{rows: [...], partial: false}`. Each row has `id` (unique, ≤32 bytes), `section`, `path`, `label`, optional `left`/`right` and corresponding `leftType`/`rightType`, `state`, and `sensitive`. Missing sides use null, not empty strings. States: `same`, `changed`, `added`, `removed`, `ignored`, `unknown`. Maximum 5,000 rows; `partial` must match the envelope status. The official algorithm additionally bounds serialized output. Missing/unsupported bodies propagate unknown to body fields and cannot yield false equality. Sensitive flags affect native display only; algorithms compare original values. Read [APIComparisonResult.swift](../../Sources/CrossDiffCore/APIComparisonResult.swift) for validation.

## 6. Runtime boundaries

### Restricted JavaScript

Each task runs in a separate JavaScriptCore helper process. Only JSON text enters JavaScript; Foundation objects and filesystem, network, module-loading and subprocess APIs are not exposed. There is no `require`, `fetch`, native-object bridge or asynchronous task protocol. Return a JSON-serializable result synchronously.

Default wall time is 15 seconds; host configuration cannot exceed 60 seconds. Helper CPU time is capped at no more than 30 seconds. The stdin envelope limit is 32 MiB, output 8 MiB, and default parent stderr limit 16 KiB. Where system policy allows reading process statistics, the host checks a 512 MiB RSS budget. This is polling and may be denied by the system; it is **not a hard memory-isolation guarantee**. Cancellation or exceeded limits terminate the helper and discard output.

This is a **restricted JavaScript runtime, not an operating-system sandbox**. A separate process and absent I/O APIs do not defend against every JavaScriptCore vulnerability. Host-side PDFKit, archive and Apple/OpenCV image parsing, Apple AVFoundation/Accelerate audio analysis and the separate Olaf helper are outside that JavaScript worker. The JavaScript time budget does not cover these native stages. There is no silent fallback to full-trust execution.

### Full-trust native executables

A native plugin receives a request JSON document on stdin, terminated by EOF, and writes exactly one result JSON document to stdout. Keep logs off stdout. The host supplies no plugin-selected command-line arguments. The program implements the contract itself; a nonzero exit signals failure.

Installation requires separate user approval tied to the executable payload digest. Different bytes in a new version cannot reuse an earlier digest approval. The stored bytes are checked again before returning an executable path and before execution; execution also requires a valid code signature. A valid ad-hoc signature can establish code integrity without verifying a publisher or providing Apple notarization.

The source package's `com.apple.quarantine` is preserved on the extracted executable. Native packages explicitly downloaded by the host also receive a provenance marker. **This preview refuses to execute quarantined native code.** It never removes quarantine or bypasses system approval; installation approval alone does not guarantee execution. There is no Gatekeeper approval UI or workflow for disabling system protections.

Full-trust code can access local files, network services and other processes. A manifest, separate process and read-only host view cannot restrict those actions. Output/task budgets do not control child processes the code creates or its external effects. Grant this trust only with an understanding of the source and behavior.

## 7. Installation and lifecycle

The local picker, dropping a `.crossdiffplugin` file and an arbitrary HTTPS download share package validation and installation review. The separate official catalog is bundled with the app and browsable offline: an explicit Download & Install action fetches a version-pinned GitHub Release asset, verifies its complete SHA-256, size, identifier/version and restricted runtime, then installs it without a second review. This path cannot authorize native code. HTTPS URLs cannot embed credentials; redirects cannot downgrade to HTTP. There is no background marketplace polling or silent plugin update. Failed downloads or invalid packages do not replace the current installation.

External plugins live under the data directory's `Plugins/` folder, normally `~/Library/Application Support/CrossDiff/Plugins/`. The development launcher uses repository-local `CROSSDIFF_DATA_DIR`. External installation does not alter the signed application bundle. Bundled plugins are assembled before app signing, updated with the app and can be disabled.

Bundled plugins can be disabled or removed from the active workspace and restored offline. Removal is a local preference, not a change to the signed app or a reduction in its size. The removed ID stays hidden across restarts, updates and Base/Full switches until explicitly restored or reinstalled.

Versions are immutable. Metadata is committed atomically before the active in-memory state changes. Different contents under the same ID and version are rejected. External plugins support enable/disable, rollback to the preceding version and uninstall. Uninstall atomically removes registration; failed cleanup may leave inactive files, without restoring their trust. Sessions retain source paths and plugin identifiers and show a recovery view when a plugin is missing or disabled.

A running task captures its validated package version; management changes invalidate old view tasks and may resume or rerun already open comparisons. Packages have no installation hooks, but installing one does not guarantee that an existing session’s algorithm will remain idle. Plugin-state migration, arbitrary historical restoration and private-state compatibility across versions are not promised.

## 8. Verification and delivery

```sh
bash scripts/tests/check-plugins-core.sh
bash scripts/tests/check-plugin-runtime.sh
bash scripts/tests/check-pdf.sh
bash scripts/tests/check-pdf-workflow.sh
bash scripts/tests/check-archive-plugin.sh
bash scripts/tests/check-plugin-workflow.sh
bash scripts/tests/check-api-import.sh
bash scripts/tests/check-api-plugin.sh
bash scripts/tests/check-api-workflow.sh
bash scripts/tests/check-photography-plugin.sh
bash scripts/tests/check-photo-engine.sh
bash scripts/tests/check-photo-metadata.sh
bash scripts/tests/check-photo-workflow.sh
bash scripts/tests/check-audio-plugin.sh
bash scripts/tests/check-audio-engine.sh
bash scripts/tests/check-audio-cache.sh
bash scripts/audio-research/build-matcher.sh
python3 scripts/audio-research/check-matcher.py
bash scripts/tests/check-audio-workflow.sh
```

Core checks exercise package/store public boundaries, persistence failure and native digest trust. Runtime checks execute the real helper and native fixtures. PDF checks exercise the algorithm, mappings and unchanged sources. Archive plugin checks run the packaged algorithm through the real child process and exercise entry limits, linear groups and malformed inputs. Workflow checks use real windows. Use synthetic data and isolated directories; native checks run serially. A build-only run or timeout does not establish GUI correctness.

Build with `bash scripts/build-app.sh` and verify with `codesign --verify --deep --strict dist/CrossDiff.app`. The deployment target is macOS 14 and the project uses Swift 5 language mode. Local builds are ad-hoc signed, not notarized releases. Intel and individual native architectures require separate validation. Before distributing plugins, review the licenses and origins of code, dependencies and resources, and disclose actual capabilities and limitations.

## Audio contract (added in 0.11.0)

See [`Plugins/Official/Audio`](../../Plugins/Official/Audio/). The manifest uses `audioAnalysis`, `audioTimeline` and pairwise mode; results use `crossdiff.audio/1`. Earlier experimental v1 hosts do not understand this domain. A host with the 0.11.0 audio capabilities is required.

Inputs contain `AudioSourceMetadata`: source identity/name, duration, sample rate, channel count, decimal-string frame count and format. Options generated by `AudioComparisonRequestOptions` contain analysis state, host-supplied correspondences and diagnostics. Correspondences retain both source-time regions, their duration ratio, method, optional pitch estimate/raw evidence score and state. Scores are not calibrated probabilities.

`AudioRegion` is a half-open interval `[start, end)` in source seconds, never frame indices in a resampled analysis copy. At most 512 correspondences are allowed, with unique IDs. Reordered, repeated and one-to-many mappings are valid; the complete result need not be monotonic. `rateRatio = right region duration / left region duration` describes that mapping, not the user's B audition rate or proof of general tempo estimation. `pitchSemitones` must be null when no pitch estimate exists. Coverage is the independent interval union on each side, excluding `rejected` entries, so repeated matches do not double-count duration.

`analysisState` is `idle`, `running`, `complete`, `partial`, `failed` or `cancelled`. Only `complete` produces envelope `status: completed`; all other states use `partial`. This describes analysis progress, not content equality or a guarantee of finding every correspondence. Host diagnostics must remain as the prefix of result diagnostics; a plugin may append explanations but cannot remove sampling, budget or unknown-state warnings.

The restricted script reports metadata differences and independent union coverage. The host validates source bounds, finite values, budgets, schema/run identity and coverage, and requires the original evidence, state and host diagnostics to be retained. PCM, waveforms and spectral grids stay outside JSON. Apple analysis and the separate Olaf C helper are trusted host components; this does not grant arbitrary native/file access to third-party scripts or establish an OS sandbox.

The contract is implemented in [`AudioComparison.swift`](../../Sources/CrossDiffCore/AudioComparison.swift). Run `check-audio-plugin.sh`, `check-audio-engine.sh`, `check-audio-cache.sh` and `check-audio-workflow.sh` under `scripts/tests/`. Package with `python3 scripts/package-audio-plugin.py`. Both editions contain the required host services and renderer.

<a id="video-contract"></a>

## Video contract (added in 0.14.0)

See [`Plugins/Official/Video`](../../Plugins/Official/Video/). The manifest uses `videoAnalysis`, `videoTimeline` and pairwise mode; results use `crossdiff.video/1`. A host with the 0.14.0 video capabilities is required. The overall protocol remains experimental v1; earlier hosts reject the unknown input kind and view.

Each `VideoSourceMetadata.pluginContent` contains only `id`, `name`, `duration`, `width`, `height`, `nominalFrameRate`, `codec`, `hasAudio` and `isHDR`. Duration is a rational time such as `{ "value": "6000", "timescale": 600 }`: a lossless decimal-string value and positive Int32 timescale, greater than zero and at most 24 hours. Dimensions describe the transformed display orientation and range from 1 to 32768 per axis. Nominal rate is 0–1000; zero means unavailable and never establishes constant frame rate. HDR describes a source transfer-function flag only. No paths, frame pixels, PCM or playback access are exposed; unknown metadata fields are rejected.

Initial `options` must be empty. The only result payload fields are:

```json
{
  "metadataDifferences": ["duration", "codec"],
  "contentCompared": false
}
```

Differences list actual changes in stable `duration`, `width`, `height`, `nominalFrameRate`, `codec`, `hasAudio`, `isHDR` order. The host recomputes these from the request. Duration uses exact rational equality: 600/600 and 1000/1000 are equal. Unknown or repeated fields, omitted or fabricated changes, and `contentCompared: true` are rejected. A `completed` result means metadata processing finished, not that pictures match, complete recordings correspond or quality has been measured.

Native host services own playback, real-PTS frame stepping, manual offset, looping and ROI. Paused differences require equal pixel dimensions and explicit Rec.709 SDR tags; third-party scripts cannot bypass that gate. Automatic segment correspondence and professional quality metrics are not exposed.

The implementation is in [`VideoComparison.swift`](../../Sources/CrossDiffCore/VideoComparison.swift). Run `check-video-plugin.sh` for Core, real JavaScript and helper checks; `check-video-source.sh` for local source services; and `check-video-workflow.sh` for the native workbench. Package with `python3 scripts/package-video-plugin.py`. Full includes the plugin; Base can install it independently, and both editions provide the native video capabilities.

## crossdiff.office/1

Office 0.1.0 requires host 0.12.0, even though the experimental protocol version remains 1. Each request compares **one selected section** of matching `kind` (`word`, `spreadsheet`, `presentation`). Inputs contain `sectionID`, `name`, and `rows`: source `id`, 1-based `position`, `label`, and `cells` with 1-based `column`, `type`, nullable source-string `value`, nullable `formula`, and nullable `format`. Numeric strings must never become JavaScript numbers. A missing cached value remains null, not an empty string. Format records are informative, not part of content equality.

`options.keyColumns` is an array of at most 16 unique column numbers (spreadsheet only). Output `payload.rows` contains unique `id`, nullable `leftID`/`rightID`, `status` (`equal`, `modified`, `added`, `removed`), `basis` (`exact`, `key`, `position`, `unmatched`), `moved` and `ambiguous`. Every source row is covered exactly once. The host validates references, states, key identity and coverage before rendering its retained originals. The plugin cannot substitute source text. Exact matches precede key matches; duplicate or empty keys are uncertain. Reorder is based on relative order, not a raw row-number difference.

The importer enforces ZIP/XML resource and entity boundaries. The renderer reports content scope and offers independent original preview. It must not label equal extracted content as whole-document or visual identity. See [Office design](../architecture/office-comparison.md) and the [official implementation](../../Plugins/Official/Office/).

```sh
source scripts/project-env.sh
python3 scripts/package-office-plugin.py --output dist/Plugins/Office.crossdiffplugin
bash scripts/tests/check-office-plugin.sh
```

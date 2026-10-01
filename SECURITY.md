# Security and privacy

CrossDiff is a local comparison application. It has no account system, server component, analytics, telemetry or automatic update service. Built-in comparisons and restricted JavaScript plugins process documents on the Mac without uploading them. Plugin downloads are separate from comparison: they connect to GitHub Releases or a user-specified HTTPS address only when the user requests installation. Full-trust native plugins have their own local and network permissions, as described below.

## Report a security issue

Open a GitHub Issue in this repository with a short summary of the concern.

Include the affected version, macOS version, expected and observed behavior, and a minimal reproduction using synthetic or redacted data. Explain the likely impact if you can. Do not include passwords, tokens, private files or sensitive logs in the issue or its attachments.

This is a small, developing project. Reports are reviewed on a best-effort basis, without a guaranteed response time. Fixes target the latest development version; older previews have no separate maintenance commitment. Do not publish a report's private details or attachments without the reporter's consent.

## Plugin execution and trust

The experimental v1 format is one bounded UTF-8 JSON `.crossdiffplugin` file with exactly one embedded JavaScript payload or base64 executable. It is not an archive and has no install hooks or companion resources. Package validation checks protocol compatibility, identifiers, runtime/payload consistency, size and SHA-256. The digest is not a publisher signature or an identity verification service. Third-party publisher information remains unverified; official bundled identifiers cannot be replaced through external installation.

**Restricted JavaScript** executes in a separate JavaScriptCore helper. The host provides JSON input and does not expose Foundation objects or filesystem, networking, module-loading or subprocess APIs. The parent bounds messages, wall time, cancellation and output; the helper applies a CPU limit. The parent also polls resident memory where the system permits it. This is a restricted runtime, **not an operating-system sandbox or a hard memory-isolation guarantee**. It does not claim protection against every JavaScriptCore vulnerability. PDFKit parses and renders PDFs in the host, outside this helper. Failed restricted execution never silently switches to full trust.

**Full-trust native code** requires explicit approval tied to its payload digest. New payload bytes need new approval. The executable's bytes and code signature are verified before execution. A valid ad-hoc signature establishes neither a verified publisher nor notarization. Native code may read or modify files, connect to servers and create other processes. The manifest, read-only comparison UI and parent process budgets do not enforce permission restrictions on those actions or guarantee termination of independently created processes.

CrossDiff preserves the source package's quarantine marker when extracting native code and marks native HTTPS downloads with provenance. This preview refuses to run a native executable carrying `com.apple.quarantine`; it does not implement a system approval UI, clear quarantine or bypass Gatekeeper. Approving installation does not override that refusal. Do not disable macOS protections to make a plugin run.

See the [experimental SDK documentation](docs/plugins/development.en.md) for exact contracts, limits and unsupported capabilities. The framework is not a general-purpose sandbox for arbitrary native plugins.

## Downloads and installation

- The official catalog ships inside the application and can be browsed offline. Clicking **Download & Install** authorizes retrieval of that exact release asset and installation after verification. The host checks the complete package's SHA-256, byte size, plugin ID/version, compatibility and restricted JavaScript runtime against the bundled catalog. This path never grants native-code trust. Catalog entries are pinned to a versioned release; there is no unrequested catalog refresh or automatic plugin update.
- Local file selection, drag-and-drop and arbitrary HTTPS downloads retain installation review and explicit native-code authorization. Packages have no installation hooks. Installing, enabling or changing a plugin can resume or rerun an already open comparison session; its algorithm then receives that session’s inputs under the selected runtime’s trust boundary.
- Downloads use an ephemeral session without application cookie storage, credential storage or a response cache. HTTPS redirects cannot downgrade to HTTP, and URLs cannot embed credentials. TLS authenticates the connection according to system trust; it does not establish the plugin author's identity.
- There is no background plugin discovery, automatic plugin update or unsolicited download. A user-selected download service still receives the requested URL and normal connection information.
- External packages are stored outside the signed application bundle. Versions are immutable, native approval is digest-bound, and metadata changes are committed atomically. Failed installation or metadata writes retain the last committed active state.
- Switching between Base and Full uses the same data directory. A bundled plugin takes precedence over a previously installed copy with the same ID; that local registration is retained so switching back does not erase the installation. External installation cannot replace an active bundled plugin.
- Uninstall removes the registration before cleaning up package files. A cleanup failure may leave inactive files; those files do not restore an active or trusted registration. Clearing comparison history does not uninstall plugins.

## Local data and file handling

- Temporary comparisons and open comparison sessions are saved locally for restoration. Session data can contain compared text, file paths and plugin identifiers; treat it as sensitive.
- Normal launches use `~/Library/Application Support/CrossDiff/`. Session and preference files are not encrypted. External plugin packages and their registry are stored in its `Plugins/` directory; bundled-plugin preferences are separate. Installed executable payloads are ordinary local files, not encrypted secrets.
- The project launcher redirects data with `CROSSDIFF_DATA_DIR` and keeps development caches, fixtures and outputs inside the repository. Never use real user sessions or documents as test fixtures.
- **Session → Clear Local Session History…** closes comparisons and removes saved history after confirmation. It does not erase original files, installed plugins, system backups or filesystem snapshots; it is not secure erasure. Language and appearance preferences are retained.
- Host comparison and editing do not automatically overwrite source files. Saving is explicit and checks for external changes. Folder copying previews additions and overwrites. The PDF plugin receives bounded page descriptors and provides read-only results; it does not rewrite the PDF.
- The bundled archive plugin receives relative virtual paths, entry types, sizes and verified content digests. Archive parsing and hashing run in the host using bounded readers and system compression libraries, outside the JavaScript helper. Comparison does not extract entries to disk or follow links. Unsafe or ambiguous paths, corrupt contents and exhausted budgets stop reading; links and special entries remain unverified. XZ dictionary declarations are checked before decoding. These limits are not an operating-system memory sandbox for native parsers. See the [supported archive subset](docs/usage.md#archives).
- Host read-only behavior is not an enforced guarantee for full-trust native plugins. Selected text and page descriptors are supplied to the chosen plugin algorithm; only install and select code appropriate for that data.
- Input documents remain untrusted parser input. Local operation does not replace macOS access controls, protect against another process acting as the same user, or prove that every file parser is free of vulnerabilities.

## Build provenance and validation

The repository build produces an **ad-hoc signed** local application and signs its helper before the app. It does not produce a Developer ID signed or notarized public release. Verify the source and origin of downloaded binaries and do not disable system-wide protections to run them.

Security-relevant changes should include regression checks at public boundaries and state exactly what was verified. Core checks cover malformed/tampered packages, role validation, persistence failures, immutable versions, quarantine propagation and digest-bound native trust. Runtime and application checks cover their respective execution and UI paths. Passing these checks is evidence for those scenarios, not a proof of general isolation, complete parser safety or compatibility with every server, system or native binary.

# Security and privacy

CrossDiff compares files locally. The application has no account system, server component, analytics, telemetry, or automatic update service. Its current comparison workflows do not require a network connection. This describes application behavior; it is not a guarantee that every input or operating environment is free of security risks.

## Report a security issue

Open a GitHub Issue in this repository with a short summary of the security concern.

Include the affected version, macOS version, expected and observed behavior, and a minimal reproduction using synthetic or redacted data. Explain the likely impact if you can. Do not include passwords, tokens, private files, or sensitive logs in the issue or its attachments.

This is a small, developing project. Reports will be reviewed on a best-effort basis; there is no guaranteed response time. Fixes target the latest development version, and older previews do not have a separate maintenance commitment.

## Local data and file handling

- Temporary comparisons and open comparison sessions are saved locally for restoration. Session data can contain compared text and file paths; treat it as sensitive.
- Normal app launches store `sessions.json` and `preferences.json` under `~/Library/Application Support/CrossDiff/`. These files use owner-only read/write permissions. They are not encrypted by CrossDiff.
- The project development launcher redirects data into the repository with `CROSSDIFF_DATA_DIR`. These files are ignored by Git.
- **Session → Clear Local Session History…** closes the comparisons and removes saved session history after confirmation. It does not erase original compared files, system backups, or filesystem snapshots; it is not a secure-erasure feature. Language and appearance preferences are retained.
- Comparison and editing do not automatically overwrite source files. Saving is explicit, with an external-change check. Folder copying shows the planned additions and overwrites before execution.
- Local operation does not replace macOS access controls or protect files from another process running as the same user. Avoid opening untrusted inputs with broader permissions than necessary.

## Build provenance

The repository's build script produces an **ad-hoc signed** local app. It does not produce a Developer ID signed or notarized public release. Verify the source and origin of any downloaded binary; do not disable macOS security protections system-wide to run it.

Security-relevant changes should include a regression check when practical and a clear account of what was verified. Do not publish a report's private details or attachments without the reporter's consent.

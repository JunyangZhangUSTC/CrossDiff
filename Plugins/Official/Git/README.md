# Git Comparison / Git 比较

A restricted JavaScript plugin included in both Base and Full. The native host selects a local repository or downloads a user-requested HTTPS/SSH repository, captures two selected sources (commit, staging area or working tree), and reads their tree metadata. `compare.js` classifies every file and counts changes; the host validates every returned row against its exact source tree before displaying the native directory tree and side-by-side detail view.

基础版和完整版均内置本插件。宿主读取用户选择的本地 Git 仓库，或按用户操作下载远程仓库，按选择读取提交／分支、暂存区或工作区；提交固定真实哈希，本地状态使用独立快照身份。插件比较目录树元信息、分类和计数，宿主逐项验证后展示目录树及左右内容。无需切换分支，不改写本地仓库、工作区或 Git 配置。

## Contract

- Input kind: `gitRepository`; result view: `gitTree`; schema: `crossdiff.git-tree/1`.
- Pairwise only, two inputs with roles `left` and `right`.
- Each content value contains `source` (`commit`, `index`, `workingTree`), `snapshot` (an opaque 1–256 UTF-8 byte identity with no ASCII control characters), nullable `commit`, Boolean `emptyBaseline`, and `entries`, each `{path, objectID, mode}`. Index and working-tree inputs must have `commit: null` and `emptyBaseline: false`; they are never disguised as commits. A repository without an initial commit may use an explicit empty HEAD baseline: source `commit`, null commit, `emptyBaseline: true`, no entries. Real commit IDs and all object IDs are 40-character SHA-1 or 64-character SHA-256, consistently within one comparison. Working-tree blob IDs do not imply writing objects into the source repository.
- Supported Git modes: regular `100644`, executable `100755`, symbolic link `120000`, submodule `160000`. Directories are implicit; symbolic links and submodules are compared as Git objects, never followed or recursively initialized.
- Native rename detection optionally supplies `options.renameHints: [{left, right}]`. The plugin accepts only distinct, one-to-one removed/added paths of compatible kinds. No script can ask the host to run arbitrary Git arguments.
- Legacy `{commit, entries}` input remains accepted and normalizes to source `commit` with snapshot `commit:<OID>`. Unknown content metadata is rejected.
- The result includes `snapshots: {left, right}`; each side echoes exactly `{source, snapshot, commit, emptyBaseline}` from the request. The host binds both sides by exact snapshot identity and rejects missing, stale or forged descriptors. These identities bind a run to captured inputs; they are not publisher signatures.
- The result also contains `rows: [{left, right, state}]` and exact `counts`. States: `unchanged`, `added`, `deleted`, `modified`, `renamed`, `typeChanged`. Mode-only permission changes remain visible as `modified`.
- All input entries must appear once in the result. A mismatch, missing entry, forged pairing, false equality, or incorrect count fails the whole result. No truncated result is labeled complete.
- Paths use exact UTF-8 byte identities; canonically equivalent Unicode filenames remain distinct. Absolute paths, traversal components, NULs and file/child collisions are rejected. Newlines, tabs and backslashes in valid Git filenames remain data, never command arguments.
- There is no repository-wide file-count or metadata-JSON limit. The host sends at most 128 complete file pairs per helper invocation (at most 128 entries per side), keeping even maximally escaped 4096-byte paths within the unchanged 16 MiB request / 8 MiB result limits. This is a transport batch boundary, not a scan limit.
- The host validates the global source graph before slicing: every source appears once, same-path pairs stay together, renames are indivisible, and file/child or object-format collisions cannot hide between batches. Each batch runs the real restricted helper with the same snapshot identities and its own run ID. Only after every result passes validation are rows and counts aggregated for publication. Cancellation or one failed batch throws away the operation; an empty comparison still executes one empty batch.
- Plugin summaries describe individual batches; the host builds the final bilingual summary from all validated rows. Progress reports verified file pairs, never unverified partial results.

## Privacy and network

The plugin receives only the two selected snapshots' relative paths, object IDs and file modes. It receives no credentials, remote URL, local filesystem path, repository history, or blob contents, and has no filesystem/network/process API. The native host streams local-state reads and resolves the selected file detail; scripts receive no content bytes. Working-tree comparisons may include untracked files when explicitly selected by the user. Local source changes invalidate captured detail instead of silently comparing different generations. Remote download and refresh require user actions; they are host operations, not plugin permissions. Existing SSH credentials and host trust are handled by the system Git/SSH setup. Private HTTPS repositories should be cloned outside CrossDiff and opened as local repositories.

## Build and checks

```sh
source scripts/project-env.sh
python3 scripts/package-git-plugin.py
bash scripts/tests/check-git-plugin.sh
python3 scripts/tests/test_plugin_inventory.py
```

The package is generated at `dist/Plugins/Git.crossdiffplugin`. It is also included in the deterministic release inventory and offline plugin catalog. The package checksum verifies content integrity; it is not a publisher signature.

## Local snapshot examples

```json
{
  "source": "index",
  "snapshot": "index:host-generated-fingerprint",
  "commit": null,
  "emptyBaseline": false,
  "entries": [{"path": "README.md", "objectID": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "mode": "100644"}]
}
```

Change `source` to `workingTree` for a working-tree snapshot and supply its independently captured identity. For HEAD ↔ staging comparisons, the other side uses a real commit descriptor or the explicit unborn-HEAD baseline. Local-state rename hints currently identify exact-content renames only; similarity thresholds and merge-base comparisons apply to two committed sources. Bare repositories have no local staging area or working tree.

`check-git-plugin.sh` also exercises the production adapter with more than 50,000 synthetic files through real helper processes, cross-batch source validation, exact renames, worst-case escaped paths, later-batch failure and cancellation. It does not open application windows.

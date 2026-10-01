# Archive Comparison / 压缩包比较

官方内置的真实受限 JavaScript 插件。宿主流式读取用户选中的压缩包或本地文件夹并计算完整普通文件 SHA-256；`compare.js` 计算路径分类、目录状态与跨路径相同内容组。算法不会收到来源绝对路径、文件句柄、原始内容或 I/O API；虚拟路径只作为本次输入的引用。

This bundled restricted JavaScript plugin computes path classifications, directory states and identical-content cohorts. The host streams selected archives or local folders and hashes complete regular-file contents. The algorithm receives catalogs, not source absolute paths, handles, original contents or I/O APIs. Virtual paths reference only this request's entries.

- Interface: `archiveCatalog` → `crossdiff.archive-tree/1`, `pairwise` only.
- Every side's entries appear exactly once in `pairs`; unverified content takes precedence over absence/type changes and yields `unknown`.
- Matching directories aggregate descendant states: unknown first, then changed, otherwise same.
- `sameContentGroups` contains complete verified ordinary-file cohorts with equal size and SHA-256, nonempty on both sides and at least two distinct paths. It does not infer a unique move or generate a Cartesian product.
- At most 10,000 entries per side, including explicit/implicit directories; normalized relative paths at most 4096 UTF-8 bytes and 128 components. NFC internal keys align with Swift's canonical-equivalent path comparison; returned IDs retain original spelling.
- Links and special files remain unverified. Input catalogs must include ancestors. Incomplete listings cannot prove one-sided additions/removals.

压缩格式、读取限制与只读边界见[使用说明](../../../docs/usage.md#archives)。扩展名只是路由提示；`.gz`、`.bz2`、`.xz` 必须实际包含受支持的 TAR，不能据扩展名承诺可读。ZIP/TAR 比较来源与 JSON 格式的 `.crossdiffplugin` 安装包是不同对象。

See [supported formats, limits and read-only behavior](../../../docs/usage.md#archives). Extensions are routing hints. Generic `.gz`, `.bz2` and `.xz` must actually contain supported TAR data. ZIP/TAR comparison sources are separate from JSON `.crossdiffplugin` installation packages.

```sh
source scripts/project-env.sh
python3 scripts/package-archive-plugin.py --output dist/Plugins/Archive.crossdiffplugin
bash scripts/tests/check-archive-plugin.sh
```

打包确定性生成单一 UTF-8 JSON，摘要覆盖脚本原始 UTF-8 字节。`org.crossdiff.archive` 为内置保留标识；第三方实现需自己的 ID，详情见[插件开发](../../../docs/plugins/development.md)。该目录沿用仓库根目录的 [AGPL-3.0-only 许可证](../../../LICENSE)与[来源说明](../../../NOTICE)。

Packaging deterministically emits one UTF-8 JSON document whose digest covers the script's original UTF-8 bytes. `org.crossdiff.archive` is a reserved bundled identifier; third-party implementations use their own IDs. See [plugin development](../../../docs/plugins/development.en.md). This directory uses the repository's [AGPL-3.0-only license](../../../LICENSE) and [notices](../../../NOTICE).

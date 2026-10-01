# CrossDiff 插件源码 / Plugin sources

- `PDF/`：内置 PDF 页面匹配算法，与宿主 PDFKit 提取及原生页面视图配合。
- `Examples/JSON/`：独立安装的第三方接口示例，算法完全在插件内实现。

These original plugin sources are part of CrossDiff, copyright © 2026 Junyang Zhang, licensed under [GNU AGPL v3](../LICENSE) (`AGPL-3.0-only`). The repository provides the corresponding host and plugin source. See the [Chinese API guide](../docs/plugins/development.md) or [English guide](../docs/plugins/development.en.md).

```sh
source scripts/project-env.sh
python3 scripts/package-pdf-plugin.py
python3 scripts/package-plugin.py Plugins/Examples/JSON --output dist/Plugins/JSON.crossdiffplugin
cp LICENSE NOTICE dist/Plugins/
```

开发产物保持项目内。分发独立插件包时一并提供 LICENSE、NOTICE、对应源码与构建说明。此目录不包含第三方依赖。

Keep development artifacts in the checkout. When distributing standalone packages, include LICENSE, NOTICE, corresponding source, and build instructions. This directory contains no third-party dependencies.

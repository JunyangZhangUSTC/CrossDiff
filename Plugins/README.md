# CrossDiff 插件源码 / Plugin sources

0.15.2 包含以下插件；版本与下载见 [README](../README.md)。基础版与完整版共享同版本宿主，区别仅在预装清单。

Version 0.15.2 includes the plugins below. See [README](../README.en.md) for editions and downloads. Base and Full share the same host and differ in their bundled plugins.

| 源码 / Source | 能力 / Capability | 预装 / Bundled |
| --- | --- | --- |
| [Official/Archive](Official/Archive/) | 虚拟目录与同内容分组 / Virtual archive trees and identical-content groups | Base、Full |
| [Official/Git](Official/Git/) | 提交／分支、暂存区与工作区的只读双栏差异 / Read-only comparisons of commits, branches, the index and working tree | Base、Full |
| [PDF](PDF/) | 页面对应与可提取文字差异 / Page alignment and extractable text differences | Full |
| [Official/Photography](Official/Photography/) | 影调、HSL、选区与有记录的曲线 / Tone, HSL, regions and recorded curves | Full |
| [Official/API](Official/API/) | 本地 HTTP／cURL／HAR 字段比较，不执行请求 / Local HTTP/cURL/HAR comparison, without executing requests | Full |
| [Official/Audio](Official/Audio/) | 波形、频谱、区域试听与同源片段候选 / Waveforms, spectra, region audition and same-source candidates | Full |
| [Official/Office](Official/Office/) | Word、Excel 跨行匹配与 PPT 内容差异 / Word, Excel row matching and PowerPoint content | Full |
| [Official/Video](Official/Video/) | 双时间线、逐帧、选区与叠加预览 / Paired timelines, frames, regions and overlays | Full |
| [Examples/JSON](Examples/JSON/) | 第三方接口与算法示例 / Independent third-party interface and algorithm example | 不预装 / Neither |

Base 可单独安装兼容的 PDF、摄影、API、音频、办公与视频包；内置插件随应用更新。全部官方包使用受限 JavaScript。专业解码、原生视图与音频匹配 helper 由宿主提供，不随脚本包安装；旧版宿主不会因安装新包而自动获得这些能力。音频自动匹配当前限固定速度同源片段，不承诺自动变速／变调识别。

Base can install compatible PDF, Photography, API, Audio, Office and Video packages separately; bundled plugins update with the app. Official packages use restricted JavaScript. Host services provide decoding, native views and the audio matching helper; installing a script cannot add missing capabilities to an older host. Automatic audio matching currently targets fixed-speed excerpts of the same recording, without automatic tempo/pitch recognition.

These original plugin sources are part of CrossDiff, copyright © 2026 Junyang Zhang, licensed under [GNU AGPL v3](../LICENSE) (`AGPL-3.0-only`). The repository provides the corresponding host and plugin source. See the [Chinese API guide](../docs/plugins/development.md) or [English guide](../docs/plugins/development.en.md).

```sh
source scripts/project-env.sh
python3 scripts/plugin_inventory.py --output dist/Plugins
# Package a separate development example with a custom output name:
python3 scripts/package-plugin.py Plugins/Examples/JSON --output dist/Plugins/JSON.crossdiffplugin
cp LICENSE NOTICE dist/Plugins/
```

第一条打包命令根据 manifest 生成全部发行插件包及 `plugins.json`，不构建应用或上传文件；清单以 [plugin_inventory.py](../scripts/plugin_inventory.py) 为准。单独打包入口和契约见上方开发规范。

The inventory command creates all release plugin packages and `plugins.json` from their manifests, without building or uploading an app. [plugin_inventory.py](../scripts/plugin_inventory.py) is the source of truth; individual packaging commands and contracts are in the development guides above.

开发产物保持项目内。分发独立插件包时一并提供 LICENSE、NOTICE、对应源码与构建说明。此目录为项目原创插件源码；宿主的 OpenCV、Olaf 等依赖说明见 [ThirdParty](../ThirdParty/)。

Keep development artifacts in the checkout. When distributing standalone packages, include LICENSE, NOTICE, corresponding source, and build instructions. This directory contains original plugin sources; host dependency notices, including OpenCV and Olaf, are under [ThirdParty](../ThirdParty/).

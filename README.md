<div align="center">

<img src="Resources/Brand/hero-zh-CN.png" alt="CrossDiff — 原生 macOS 对比工具，支持文本、文件夹和图片" width="100%">

**看清每一处变化，让文件留在自己手中。**

为 Mac 打造的免费开源对比工具。<br>
原生交互，细致打磨，所有比较都在本地完成。

[简体中文](README.md) · [English](README.en.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-304A68?style=flat-square)](#快速开始)
[![Swift](https://img.shields.io/badge/Built_with-Swift-F05138?style=flat-square)](Package.swift)
[![AGPL v3](https://img.shields.io/badge/License-AGPL_v3-22816B?style=flat-square)](LICENSE)
[![Preview](https://img.shields.io/badge/Status-Developer_preview-7C6DAA?style=flat-square)](CHANGELOG.md)

[下载预览版](https://github.com/JunyangZhangUSTC/CrossDiff/releases) · [功能特色](#让日常比较更顺手) · [快速开始](#快速开始) · [隐私](#文件留在你的-mac-上) · [路线图](#持续开发公开演进) · [参与贡献](CONTRIBUTING.md)

</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/text-zh-CN-dark.png">
  <img src="docs/assets/screenshots/text-zh-CN-light.png" alt="CrossDiff 原生窗口：对齐的代码双栏、精确到字符的红绿差异高亮" width="100%">
</picture>

<p align="center"><sub>使用虚构示例文字渲染的真实应用窗口；截图随 GitHub 的浅深色主题切换。</sub></p>

## 让日常比较更顺手

临时粘贴两段文字、检查两个代码文件、核对目录，或查看图片变化。CrossDiff 把这些工作放在简洁、专注的同一个窗口里。

| | |
| :--- | :--- |
| **原生 macOS 体验**<br>使用 SwiftUI 和 AppKit，原生文本编辑、标准菜单与 Mac 快捷键，不内置浏览器运行环境。 | **本地运行，保护隐私**<br>无需上传、登录或联网；应用不包含分析追踪，也不主动发送网络请求。 |
| **免费开源**<br>采用 AGPL v3 协议，源码可查看、构建和修改。无订阅、试用倒计时或付费功能墙。 | **细节清晰，原文完整**<br>字符级和行级差异、对应行对齐、Unicode 文本处理，让增加与删除都看得清。 |
| **修改由你掌握**<br>左右编辑、逐块合并、独立撤销、手动保存。仅做比较不会覆盖原文件。 | **简洁，也讲究**<br>浅深色主题、克制的高亮、比较标签页和同步滚动，完整支持简体中文与 English。 |

## 多种比较，一个工具

| 比较对象 | 当前已支持 |
| :--- | :--- |
| **文本与代码文件** | 粘贴或打开两段文本，查看字符或整行变化，左右编辑、逐块合并、查找替换，并保留独立撤销记录。 |
| **文件夹** | 递归扫描、筛选差异、查看修改或单侧存在的文件，向另一侧复制选中文件前预览新增与覆盖项。 |
| **图片** | 并排、叠加、拖动擦除分界线、差异图和缩放。 |

开启 **显示删除**，右侧会把移除的内容显示为红色删除线。此功能默认关闭，开启后为只读审阅：修订标记不会写入原文或保存文件。普通复制仅包含原文，显式选择“含修订内容”的复制才会带上变化。

<details>
<summary><b>查看“显示删除”效果</b></summary>
<br>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/deletions-zh-CN-dark.png">
  <img src="docs/assets/screenshots/deletions-zh-CN-light.png" alt="CrossDiff 在右侧只读审阅中用红色删除线显示被移除的文字" width="100%">
</picture>
</details>

## 快速开始

**当前预览版：0.4.0。** 需要 **macOS 14 或更高版本**。使用已构建的应用无需安装 Swift 开发工具。

本预览版已在 **Apple 芯片（arm64）** 上验证，Intel 构建尚未实测。

**[下载预览版 → GitHub Releases](https://github.com/JunyangZhangUSTC/CrossDiff/releases)**

在已公开版本的 **Assets** 中选择 `CrossDiff-<版本>-macOS-arm64.zip`，解压后打开应用。同一版本附有对应源码、构建信息和 `SHA256SUMS` 校验和。发布流程先生成供维护者审核的草稿；如果页面还没有公开版本，请使用下面的源码构建方式。

**从源码构建：** 安装支持 **Swift 6.0 package manifest** 的开发工具，下载或克隆仓库后，在项目根目录运行以下命令。项目使用 Swift 5 语言模式，构建对应本机架构。

```sh
bash scripts/build-app.sh
bash scripts/open-dev-app.command
```

应用生成在 `dist/CrossDiff.app`。项目启动入口会把开发会话、偏好与缓存都留在当前目录，不安装全局依赖，也不写入 `/Applications`。

### 首次在 macOS 上打开

当前预览版尚未使用 Apple 开发者身份签名（Developer ID）。**主要是这个开发者签名和公正要交年费，实在好贵。**本地构建仅使用 ad-hoc 签名，因此首次打开下载的应用时，macOS 可能需要你手动确认。

核对下载来源后：

1. 解压应用，先尝试打开一次 **CrossDiff.app**。
2. 如果提示无法验证开发者，前往 **系统设置 → 隐私与安全性**，向下找到“安全性”，点击 CrossDiff 对应的 **仍要打开**。
3. 在确认窗口点击 **打开**，按提示完成身份验证。之后通常可以直接双击启动。

以上为 [Apple 官方提供的打开方式](https://support.apple.com/zh-cn/102445)，无需全局关闭 Gatekeeper。签名与打包说明见[发布指南](docs/releasing.md)。

**源码公开，行为可核验：** 仓库提供源码、构建方式及发布校验和，你可以审查代码、核对对应版本或自行编译。CrossDiff 在本地完成比较，不上传文件。开源和校验和提供核验依据，不代表对任何构建或下载来源作绝对安全保证。

**一分钟上手**

1. 在左右两侧粘贴文字，或点击 **打开…** 选择文件、文件夹。多项输入可明确配对为独立比较标签页。
2. 逐处查看差异，编辑任意一侧，只合并需要的改动。
3. 手动保存结果。要开始新的文本比较，可以 **清空两侧**；误清空后可立即恢复。

仓库内附有[两份 Swift 示例](examples/)，便于体验。详细行为与完整快捷键见[使用指南](docs/usage.md)。

| 操作 | 快捷键 |
| :--- | :--- |
| 打开文件或文件夹 | ⌘O |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| 查找 / 查找并替换 | ⌘F / ⌥⌘F |
| 下一个 / 上一个匹配 | ⌘G / ⇧⌘G |
| 下一处 / 上一处差异 | ⌥⌘↓ / ⌥⌘↑ |
| 保存当前编辑侧 | ⌘S |
| 设置 / 切换语言 | ⌘, |

在 **CrossDiff → 设置/Setting… → 语言/Language** 中选择简体中文或 English，界面即时更新，无需重启。

## 文件留在你的 Mac 上

CrossDiff 在本机完成比较与编辑，不包含网络请求、遥测、云端同步、账号系统或自动更新服务；使用应用不会把文档内容发送到服务器。

临时比较可通过本机会话恢复。正常启动时，数据位于 `~/Library/Application Support/CrossDiff/`；项目启动入口则使用项目内独立目录。**会话文件包含明文内容与路径，CrossDiff 不对它们加密。** 可以从“会话”菜单清除本地记录；如果原文件放在云同步目录，其同步仍由对应服务负责。

边界与安全问题报告方式见 [SECURITY.md](SECURITY.md)。README 徽章和 GitHub 属于外部网页服务，不是桌面应用的组成部分。

## 持续开发，公开演进

CrossDiff 正在持续开发，首先打磨可靠的文本、文件夹与图片比较，再逐步扩展：

- 上下文折叠、更完善的目录工作流与无障碍体验。
- 面向论文、文档的 PDF 比较。
- 后续加入结构化表格、Word、三方合并与导出。

**PDF、Word、表格和三方合并尚未实现。** 图片当前使用最长边不超过 1600 像素的预览，文本文件上限为 20 MB，文件夹操作尚不支持完整同步。详见[实现边界](docs/development.md#current-implementation-limits)、[路线图](docs/roadmap.md)与[更新记录](CHANGELOG.md)。

## 一起完善 CrossDiff

欢迎提交问题、翻译、设计反馈和范围明确的改进。请先阅读[贡献指南](CONTRIBUTING.md)；[开发指南](docs/development.md)介绍项目结构、构建与测试方式。

```sh
bash scripts/check.sh       # 核心行为检查，不依赖 XCTest
bash scripts/check-all.sh   # 完整检查，需要原生 macOS 应用会话
```

## 许可证

Copyright © 2026 **Junyang Zhang**。CrossDiff 使用 [GNU Affero General Public License v3.0](LICENSE)（`AGPL-3.0-only`）。项目版权说明见 [NOTICE](NOTICE)。

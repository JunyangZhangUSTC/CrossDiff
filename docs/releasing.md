# 发布 CrossDiff

[Release 工作流](../.github/workflows/release.yml) 为同一个源码提交构建 **基础版（Base）**、**完整版（Full）**和独立插件包，上传到 [GitHub Releases](https://github.com/JunyangZhangUSTC/CrossDiff/releases)，下载回读并校验后保留为草稿预览版。维护者点击 **Publish release** 后，用户就能下载应用，基础版也能从应用内下载并安装本版本的官方插件。

普通 `main` 推送运行检查，不发布版本；推送版本标签才会生成 Release 草稿。所有版本均免费，无需注册。两个发行版使用同一套本地比较引擎与会话格式，没有付费功能区别。

当前源码计划为 **0.9.0**，尚未发布；已公开下载仍是 **0.8.0**。以下清单与命令说明如何准备 0.9.0，不代表对应下载已可用。

## 版本包含什么

| 发行内容 | 当前包含 |
| --- | --- |
| **Base 基础版** | 文本与文本文件、文件夹、图片、二进制 / Hex，以及官方压缩包插件。 |
| **Full 完整版** | 基础版的全部内容，加上 PDF 与 Photography 插件，即当前源码的全部官方插件。 |
| **独立官方插件** | 压缩包、PDF、Photography 各自的 `.crossdiffplugin` 包；同版本基础版可单独安装 PDF／摄影，当前内置插件随应用升级。 |
| **开发示例** | 独立的 JSON 示例插件；文件名明确标记 `Example`，不预装进 Full，也不进入官方插件目录。 |

“完整版”指本版本所有已实现的官方插件，**不包含路线图里尚未实现的 Office、音视频或模型插件**。添加新插件时，在 [plugin_inventory.py](../scripts/plugin_inventory.py) 的显式清单中登记发行范围、身份和来源，避免把实验示例误装进正式版本。

当前分发 **Apple 芯片 / arm64，macOS 14+**。本地可按宿主架构构建，但 Intel 发行尚未验证；没有提供 Universal 包。应用仅使用 ad-hoc 签名，尚无 Developer ID 签名或 Apple 公证。工作流使用仓库自带的短期 `GITHUB_TOKEN`，无须上传个人令牌、SSH 密钥或 Apple 证书。

## 创建本次 Release

1. 完成受影响的核心与原生窗口验证，并记录未验证场景。CI 的 `--build-only` 只证明原生检查程序能够编译，不能替代真实窗口验收。
2. 更新 `Resources/Info.plist` 的版本和递增构建号、`CHANGELOG.md`、中英文 README，以及 `docs/releases/<版本>.md` 双语发布说明。当前计划版本为 **0.9.0**（构建号 18）。README 默认下载链接继续指向已公开版本，发布新版本后再更新；同时去掉新版发布说明中的“尚未发布”标记。
3. 如果插件的代码或 manifest 有变化，递增该插件的 `version`。应用版本和插件版本独立；不要在同一插件版本下替换已经公开的包。
4. 提交并推送精确的发行状态到 `main`。发行脚本拒绝脏工作区、未跟踪文件以及 `assume-unchanged` / `skip-worktree` 隐藏修改。
5. 版本与发布说明一致后，从项目根目录的 Bash 运行：

```sh
source scripts/project-env.sh
git switch main
git push origin main
git tag -a v0.9.0 -m "CrossDiff 0.9.0 preview"
git push origin v0.9.0
```

标签必须等于 `v` 加 `CFBundleShortVersionString`，对应提交必须可从 `origin/main` 到达。以后发布时替换版本号；不要移动已公开的版本标签。

推送标签后，打开 [Actions → Release](https://github.com/JunyangZhangUSTC/CrossDiff/actions/workflows/release.yml)。也可以使用 **Run workflow** 并填写一个已经存在的远端标签。手动运行不会创建或移动标签。

工作流验证标签、版本、源码提交与发布说明，运行检查，构建两个发行版，审计源码和构建产物，创建草稿，并逐一下载已上传附件核对 SHA-256。构建任务只有只读仓库权限，上传任务才有 `contents: write`。Apple 芯片运行环境为 GitHub 的 `macos-15` 标准 runner，构建时还会检查真实架构。[GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

运行成功后，在 Releases 中检查草稿内容并点击 **Publish release**。预览阶段保留 **Pre-release** 标记。**草稿附件不能作为公开插件下载源，发布草稿后应用内下载才可用。** GitHub 也建议在启用不可变发布时先上传完整附件，再发布草稿。[GitHub 发布说明](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

## Release 的全部附件

```text
CrossDiff-0.9.0-base-macOS-arm64.zip
CrossDiff-0.9.0-full-macOS-arm64.zip
CrossDiff-Plugin-Archive-0.1.0.crossdiffplugin
CrossDiff-Plugin-PDF-0.1.0.crossdiffplugin
CrossDiff-Plugin-Photography-0.1.0.crossdiffplugin
CrossDiff-Example-JSON-0.1.0.crossdiffplugin
CrossDiff-0.9.0-source.tar.gz
plugins.json
BUILD-INFO.txt
SHA256SUMS
```

这里的插件版本来自各自的 manifest，后续独立递增。Photography 0.1.0 需要支持 `photoAnalysis` 的 0.9.0 宿主，不能让 0.8.0 应用通过新目录假装获得宿主尚无的摄影能力。所有附件都由脚本生成；不要手动重命名插件包或只上传应用 ZIP。`SHA256SUMS` 覆盖除自身之外的每一个附件。`BUILD-INFO.txt` 记录应用版本、构建号、完整源码提交、架构、两版应用文件名和签名状态，不包含开发者的本机路径。

## 官方插件目录与应用内安装

[plugin_inventory.py](../scripts/plugin_inventory.py) 是打包清单的唯一来源，同时生成确定性的插件包与 `plugins.json`：

- 目录格式为 `formatVersion: 1`，`releaseTag` 固定到本次应用版本，例如 `v0.9.0`。
- 每项包含 `id`、插件 `version`、中英文 `name` / `summary`、`asset`、`url`、**完整插件包字节**的 `sha256` 与 `size`。
- 地址固定到本仓库 `releases/download/<releaseTag>/<asset>`；不用会随最新版本变化的地址。
- 两版应用都内置**逐字节相同**的 `Contents/Resources/OfficialPlugins.json`，与 Release 的 `plugins.json` 相同。基础版因此可以离线展示尚未安装的官方插件。

应用启动或打开插件页不需要联网刷新目录；只有用户选择安装时才下载对应插件包。应用验证下载内容后完成官方插件安装；本地选择 / 拖入包及第三方安装保留现有审查流程。安装只影响本机的插件目录，不上传比较文本或文件。已安装的内置能力与受限插件在本机执行；显式启用的完全信任插件拥有不同权限边界，详见 [SECURITY.md](../SECURITY.md)。

目录由随应用发布的资源提供，当前不会静默拉取“最新插件”或自动升级。未来若要独立更新目录，需要另行设计版本兼容与信任验证。插件包的内层脚本摘要与目录中的整包摘要用途不同，不能混用。

## 在本机准备同样的附件

普通开发默认构建 Full，不要求干净工作区：

```sh
bash scripts/build-app.sh
bash scripts/open-dev-app.command
```

只构建基础版并保留默认开发应用：

```sh
bash scripts/build-app.sh --edition base --output dist/editions/base/CrossDiff.app
```

从**干净、已提交**的发行状态准备全部附件：

```sh
bash scripts/package-release.sh
```

产物位于 `dist/releases/<版本>-<提交短号>/`；默认开发应用 `dist/CrossDiff.app` 仍为 Full，基础版位于 `dist/editions/base/CrossDiff.app`。构建、临时目录、测试数据和产物都留在当前项目；自定义 Bash 命令先加载 `scripts/project-env.sh`。

打包脚本对每版核对插件清单、离线目录、元数据、许可证和签名，并审计产物；ZIP 去除扩展属性、资源分叉和本机用户 ID，再解压到项目内检查真实附件的签名。源码通过 `git archive` 从同一固定提交生成，不包含 `.git`、本机缓存或被忽略的开发资料。脚本拒绝覆盖同版本同提交的已有发行目录，不安装应用、不上传文件，也不修改 Git 历史。

OpenCV 4.12.0 的 `core`／`imgproc` 在两个宿主中静态链接，不放入受限 JavaScript 摄影包。首次构建从固定 URL 下载、核验依赖源码与必要工具，所有缓存位于项目 `.build/photo-deps/`；发布构建不是无第三方依赖构建。应用随包保留 `Contents/Resources/ThirdParty/OpenCV/` 的许可证与来源说明；源码归档保留对应 `ThirdParty/OpenCV/` 文档和可复现依赖脚本，但不包含被忽略的依赖构建缓存。发布前核对这些声明和实际内容一致。

摄影回归包括引擎、XMP、真实插件和完整窗口检查。RAW 验证应记录实际样片、相机／编码和系统版本；不能仅凭被接收的后缀列表宣称支持所有机型。库和系统解码器的存在不等于该版本已通过验证。

发布相关离线回归：

```sh
source scripts/project-env.sh
python3 -m unittest discover -s scripts/tests -p 'test_plugin_inventory.py'
python3 -m unittest discover -s scripts/tests -p 'test_github_release.py'
python3 scripts/audit-publication.py --history --app dist/CrossDiff.app
```

## 重试与发布边界

同一源码提交可以重试草稿上传。上传器校验本地标签、远端标签、提交中记录的插件来源、全部附件校验和、Base / Full 实际内置包、应用与 Release 目录的一致性，并下载回读确认上传结果。它不会覆盖已经公开或不可变的 Release，也不会把另一个提交的草稿改成本次版本。

如果应用版本、插件代码或附件需修正，使用新的提交和版本；不要重新上传不同内容来替换已经公开的插件包。工作流定义已配置不等于远端运行已经通过，只有实际 Actions 结果与附件回读验证才是本次发布的证据。

应用尚未公证，ad-hoc 签名仅用于完整性验证，不证明发布者身份。首次打开方式见 [中文 README](../README.md#首次在-macos-上打开) 和 [English README](../README.en.md#first-launch-on-macos)。不要让用户全局关闭 macOS 安全保护。

CrossDiff 使用 GNU AGPL v3。每个公开应用都附带同提交源码、`LICENSE` 和 `NOTICE`；保留这些文件，分发义务以许可证原文为准。自动敏感信息扫描只能减少遗漏，公开截图、示例和说明仍需人工检查。

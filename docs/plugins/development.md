# 插件开发 · 实验 v1

状态：2026-10-05，面向 CrossDiff 0.15.0 开发源码（Git/Photography/API/Audio/Office/Video 0.1.0，Archive 0.1.1，PDF 0.2.0）。协议、包格式与宿主视图仍是实验接口；本文描述当前实现，不承诺未来版本无需迁移。[English](development.en.md)

实现依据为 [PluginProtocol.swift](../../Sources/CrossDiffCore/PluginProtocol.swift)、[PluginPackage.swift](../../Sources/CrossDiffCore/PluginPackage.swift)、[PluginStore.swift](../../Sources/CrossDiffCore/PluginStore.swift) 与 [PluginRunner.swift](../../Sources/CrossDiff/PluginRunner.swift)。早期[框架设计](../architecture/compare-everything.md)描述的远期能力不代表本版本已经支持。

## 1. 当前可用范围

插件为宿主提供比较算法；宿主负责读取输入、运行任务以及显示结果。当前输入类型与宿主视图如下：

| 输入类型 | 宿主交给插件的内容 | 结果视图 |
| --- | --- | --- |
| `text` | 已解码文字 `{text: "…"}` | `table`：只读结果表格 |
| `pdf` | 页面文字、尺寸与预览指纹 | `documentPages`：原生 PDF 页面与文字差异；也可返回 `table` |
| `archiveCatalog` | 压缩包或本地文件夹的虚拟路径、类型、大小、完整内容摘要与验证状态 | `archiveTree`：只读目录树与跨路径同内容组 |
| `gitRepository` | 两侧提交／暂存区／工作区快照的来源身份、相对路径、对象 ID、Git 模式及重命名证据 | `gitTree`：仓库目录树与所选文件的只读双栏差异 |
| `httpExchange` | 有界 HTTP／cURL／HAR 导入，规范化为带类型的分区与字段 | `apiExchange`：请求／响应字段双栏差异 |
| `photoAnalysis` | Apple／OpenCV 管线生成的有界归一化 RGB／HSL 分布、中性色比例及分析说明 | `photography`：双图、选区、直方图、记录曲线与拍摄信息 |
| `audioAnalysis` | 有界源元数据与宿主匹配证据；不含 PCM、波形或谱图网格 | `audioTimeline`：双时间线、声道波形、时频图、选区与 A/B 试听 |
| `officeDocument` | DOCX/XLSX/PPTX 所选部分的类型化单元格、原位置、公式与保存结果 | `officeDocuments`：原生表格与段落／幻灯片内容 |
| `videoAnalysis` | 所选视频的有界元数据；不含路径、帧像素、PCM 或对应关系 | `videoTimeline`：原生双画面与时间线、手动对齐、暂停对照 |

内置 [PDF 插件](../../Plugins/PDF/)的 JavaScript 决定页面对应与分类；PDFKit 在宿主侧提取并显示页面。独立 [JSON 示例插件](../../Plugins/Examples/JSON/)自行比较 JSON 顶层键值，使用相同安装和执行协议。

当前应用只发起 `pairwise` 两方任务。公共类型同时区分 `threeWayMerge` 与 `multiSubject` 并验证角色，但本版没有它们的用户界面或比较/合并算法。不得声明一个插件实际不支持的模式，也不得收到多个输入时静默只比较前两个。

自定义原生视图、任意 schema 渲染、工件/资源句柄、伴随动态库、插件依赖、插件自定义远程来源提供器、插件导出及写回尚未提供。Git 的本地仓库读取和用户主动发起的远程下载由固定宿主能力提供，不向脚本开放网络接口。现有文本、文件夹、图片与二进制 Hex 比较保持宿主功能。

## 2. 从示例开始

在项目根目录的 Bash 中运行；输入、输出和缓存都留在项目内：

```sh
source scripts/project-env.sh
python3 scripts/package-plugin.py Plugins/Examples/JSON --output dist/Plugins/JSON.crossdiffplugin
```

在 CrossDiff 的插件管理窗口选择“从文件安装…”，或把生成的文件拖入应用。核对名称、版本、标识与运行方式后安装。通过比较菜单选择 JSON 插件并打开一对文件；普通 `.json` 文件仍默认进入原有文本比较，示例还声明 `.cdjson` 扩展名。

PDF 的可重复打包入口为：

```sh
source scripts/project-env.sh
python3 scripts/package-pdf-plugin.py --output dist/Plugins/PDF.crossdiffplugin
```

完整版内置 `org.crossdiff.pdf`；基础版可从官方目录单独安装。外部包不能覆盖当前版本已内置的同 ID 插件。要实验自定义 PDF 插件，请在项目内建立自己的源码目录并使用自己的 ID。打包脚本只生成格式；安装时的宿主校验仍是必需步骤。

官方 Archive 插件的打包入口为：

```sh
source scripts/project-env.sh
python3 scripts/package-archive-plugin.py --output dist/Plugins/Archive.crossdiffplugin
```

[Archive 源码](../../Plugins/Official/Archive/)中的脚本实际计算路径分类、目录状态和内容组。`org.crossdiff.archive` 同样是内置保留 ID；第三方实现使用自己的 ID，并可复用相同的受限运行时和原生目录视图。普通 ZIP/TAR 是比较来源，`.crossdiffplugin` 才是安装包，两者用途不同。

官方 Git 插件同时内置于基础版和完整版，开发打包入口为：

```sh
source scripts/project-env.sh
python3 scripts/package-git-plugin.py --output dist/Plugins/Git.crossdiffplugin
```

[Git 源码与说明](../../Plugins/Official/Git/)包含真实目录分类算法。`org.crossdiff.git` 为内置保留 ID；自定义实现需使用自己的 ID，并配套 0.15.0 或具备相同 Git 宿主能力的版本。`fileExtensions: ["git"]` 是清单入口标识，不要求仓库目录以 `.git` 结尾。新建 Git 比较时选择一个仓库，再为每侧选择提交／分支、暂存区或工作区；不是给脚本传入两个仓库路径。接口详见下方 `crossdiff.git-tree/1`。

摄影插件同样通过普通包安装与受限进程运行：

```sh
source scripts/project-env.sh
python3 scripts/package-photography-plugin.py --output dist/Plugins/Photography.crossdiffplugin
```

[Photography 源码](../../Plugins/Official/Photography/)根据宿主的统计结果计算双语差异说明。OpenCV 不是装在插件包内的原生代码，而是同版本 Base／Full 宿主提供的固定分析能力；Full 预装 `org.crossdiff.photography`，Base 可安装独立包。该契约可由其他 ID 的插件使用，不依赖官方 ID 的特殊执行路径。0.8.0 宿主不认识此输入类型；摄影能力始于 0.9.0，当前开发应配套 0.11.0 宿主和插件。尚未发布的目录 URL 不代表下载已可用。

官方 API 插件的打包入口：

```sh
source scripts/project-env.sh
python3 scripts/package-api-plugin.py --output dist/plugins/CrossDiff-Plugin-API-0.1.0.crossdiffplugin
```

Full 预装 `org.crossdiff.api`，Base 可独立安装；需要始于 0.10.0 的 HTTP 宿主能力，当前 0.11.0 宿主已包含。协议版本仍为 v1，但旧宿主不认识新输入类型。宿主只解析本地数据，不执行命令或请求。参见 [API 源码](../../Plugins/Official/API/)和[范围设计](../architecture/api-comparison.md)。

官方 Audio 包使用同一安装和受限执行流程：

```sh
source scripts/project-env.sh
python3 scripts/package-audio-plugin.py --output dist/Plugins/Audio.crossdiffplugin
```

Full 预装 `org.crossdiff.audio`，同版本 Base 可安装独立包。音频分析与 Olaf 指纹 helper 属于 0.11.0 宿主能力，插件只整理宿主元数据和证据，不包含原生库，也不能替换宿主 DSP 或指纹实现。见[音频源码](../../Plugins/Official/Audio/)与本文下方的音频契约。

## 3. 包是一个 JSON 文件

`.crossdiffplugin` 是一个有大小上限的 UTF-8 JSON 文件，**不是目录或 ZIP**。它没有安装脚本、归档路径、资源列表或原生伴随库。顶层字段如下：

| 字段 | 规则 |
| --- | --- |
| `formatVersion` | 整数 `1` |
| `manifest` | 下述清单对象 |
| `script` | `restrictedJavaScript` 的非空 UTF-8 JavaScript 字符串 |
| `executable` | `trustedExecutable` 的非空可执行文件 bytes，以 JSON base64 字符串表示 |
| `sha256` | payload 原始字节的 SHA-256，小写 64 位十六进制 |

`script` 和 `executable` 必须恰好提供一个，并与 `runtime` 对应。脚本摘要针对字符串的 UTF-8 字节，不是包文件或 JSON 转义后的字节；原生摘要针对 base64 解码后的完整可执行文件。签名应在打包和计算摘要**之前**完成，签名后修改文件会改变摘要。

包最多 **16 MiB**；脚本最多 **2 MiB**；原生可执行文件最多 **8 MiB**。本地读取拒绝目录、最终路径为符号链接的文件及超限输入。摘要验证只证明包中声明与 payload 一致，不能验证作者身份；发布者在安装预览中显示为未验证。

清单示例：

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

字段名严格使用上述 camelCase，双语字段是 `zhHans` / `en`。ID 最多 128 UTF-8 字节，以小写英文字母开头，由小写字母、数字及分隔段的 `.` / `-` 组成。版本为最多 64 字节的三段版本号，可带 prerelease/build 后缀。名称每种语言最多 512 字节，说明最多 4096 字节，均不能为空。

`fileExtensions` 为 1–32 个不重复、小写且不带点号的扩展名；单项最多 16 字节，可含字母、数字、`_`、`-`。`supportedModes` 非空且无重复；协议范围必须覆盖当前宿主版本 `1`。`documentPages` 只接受 `pdf` 输入。`archiveCatalog` 与 `archiveTree` 必须配套，且 `supportedModes` 必须为 `["pairwise"]`；不能把该输入交给 `table`。`photoAnalysis` 同样必须配套 `photography` 和 `supportedModes: ["pairwise"]`，不能返回 `table`。`gitRepository` 必须配套 `gitTree` 和 `supportedModes: ["pairwise"]`，不能返回其他视图。标识保留名单由宿主明确提供，不会因为第三方填写了类似官方的名称就授予官方身份。

## 4. 请求与 JavaScript 入口

脚本定义一个同步函数：

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

该最小示例仅适合短文字；整份长文件不能塞进一个表格单元格。生产插件应按语义拆行、遵守下述单元格与结果上限，必要时返回 `partial` 和双语诊断。

请求结构：

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

不要依赖输入数组顺序，使用 `role`。`id` 必须唯一；`runID` 原样返回。公共验证器要求：

| 模式 | 角色形状 | 当前应用执行 |
| --- | --- | --- |
| `pairwise` | 恰好 `left`、`right` | 支持 |
| `threeWayMerge` | 恰好 `base`、`ours`、`theirs` | 仅契约验证 |
| `multiSubject` | 3–32 个 `peer`，各自 ID 唯一 | 仅契约验证 |

JSON 值仅包含对象、数组、字符串、有限数字、布尔和 null。Swift 侧为 `PluginJSONValue`，提供类型访问器及字符串/整数下标；缺失键与 `.null` 不同。JSON 数字经 Double/JavaScript Number 表达，精确大整数不能假设无损，应由领域协议用字符串表达。

宿主文字插件每侧最多读 2 MiB 的普通文件，解码后的 UTF-8 文字最多 4 MiB；整个编码请求最多 16 MiB。输入内容不包含任意文件句柄、凭据或文件系统 API。

## 5. 结果 schema

所有结果包含 `protocolVersion`、`runID`、`schema`、`status`、`summary`、`diagnostics` 和 `payload`。`status` 仅为 `completed` 或 `partial`。脚本抛错、进程退出、取消、超时或协议失败由宿主作为失败处理，不以空结果代替成功。

`summary` 使用 `zhHans` / `en`，每种语言最多 16 KiB。`diagnostics` 最多 128 项，每项双语非空且每种语言最多 4096 字节。payload 必须为对象，完整编码结果最多 8 MiB。宿主核对协议、runID 和清单视图对应的 schema；旧任务结果不能替换当前任务。

### `crossdiff.table/1`

清单 `resultView` 为 `table`，payload 为：

```json
{"rows": [{"label": "name", "left": "old", "right": "new", "state": "changed"}]}
```

最多 10,000 行。`label`、`left`、`right` 必须是字符串，各最多 32,768 UTF-8 字节；`state` 为 `same`、`changed`、`added`、`removed` 或 `unknown`。不要返回 HTML、原生视图描述或可执行代码作为单元格。宿主负责差异颜色、筛选、文本选择以及双语界面。

JSON 示例按解析后的值比较，忽略对象键顺序与空白；重复键不能据此做无损判断。它限制键数量、嵌套深度和安全数字范围，不应被描述为原始 JSON 字节相等检查。

### `crossdiff.document-pages/1`

清单 `inputKind` 为 `pdf`、`resultView` 为 `documentPages`。每侧 content 为：

```json
{
  "pages": [{"index": 0, "text": "页面文字", "width": 595, "height": 842,
             "fingerprint": "host-generated-sha256", "textTruncated": false}],
  "truncated": false
}
```

页面下标从 0 开始，尺寸以 PDF 页面点数表达。当前宿主每个 PDF 最多读取 48 MiB，提取前 200 页，每页最多 32,768 个 UTF-16 码元、每文档最多 262,144 个 UTF-16 码元。页面指纹来自最长边 384 像素的预览；原始 PDF 数据保留在宿主，不作为 base64 传给脚本。

结果 payload 示例：

```json
{"pairs": [
  {"left": 0, "right": 0, "kind": "same"},
  {"left": null, "right": 1, "kind": "added"},
  {"left": 1, "right": 2, "kind": "changed"}
]}
```

`kind` 为 `same`、`changed`、`added`、`removed` 或 `unknown`。新增仅有 right，删除仅有 left；其他分类必须有两侧索引。索引必须在本次已提取页面范围内，每侧页面恰好出现一次，不允许重复或漏掉。宿主对映射验证后才渲染。

从 0.12.2 宿主与 PDF 0.2.0 插件开始，payload 还可附带 `"alignment": {"strategy": "smart", "reliablePairs": 2}`，或 `"alignment": {"strategy": "pageNumber", "reason": "insufficientEvidence", "reliablePairs": 0}`。回退原因可以是 `insufficientEvidence` 或 `ambiguousEvidence`；`smart` 不携带回退原因。`reliablePairs` 表示可靠的顺序锚点数，不是所有配对的置信率，不能超过实际双侧配对数量。没有这项元数据的旧插件仍可使用按页码与手动选页；新宿主在智能模式下保守回退。旧宿主可读取原 `pairs`，但不会因此获得新控件。

宿主默认按原始页码比较，也提供智能匹配和手动左右独立选页。PDF 0.2.0 使用唯一预览或有信息量文字寻找顺序一致的锚点；多页文档至少需要两个锚点并覆盖较短文档半数。低信息量单页不能仅靠预览指纹移位；短标题、重复或截断文字不作为充分文字证据。证据不足时按页码回退；有锚点但缺少明确对应证据的间隔按相对顺序对照，仍需人工核对。单侧页不必然代表版本插删。

`same` 表示文字与预览匹配，不代表 PDF 文件字节相同或全分辨率视觉相同。扫描/空白页可能没有可提取文字；没有 OCR 或语义理解。截断或禁止文字复制会保留限制信息；加密锁定、损坏、无页面等情况明确失败。没有密码输入或 PDF 回写能力。[实现与完整限制](../../Sources/CrossDiff/PDFComparisonDocument.swift)

### `crossdiff.archive-tree/1`

清单必须声明 `inputKind: "archiveCatalog"`、`resultView: "archiveTree"` 和 `supportedModes: ["pairwise"]`。宿主流式读取用户选中的归档或文件夹，计算完整普通文件的 SHA-256；插件只收到以下 content，不接收来源绝对路径、文件句柄、原始文件内容或读取回调：

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

每侧最多 10,000 条，包含宿主补齐的隐式父目录。`id == path`，为最多 4096 UTF-8 字节、最多 128 层的规范相对虚拟路径；无绝对路径、空段、`.`、`..`、NUL、反斜线或 Windows 盘符前缀。路径区分大小写，保留原始 Unicode 拼写；宿主拒绝同侧规范等价的重复路径，插件用 NFC 内部键匹配左右路径，并返回原始 ID。路径仅是显示及引用数据，不能被当作本地文件读取授权。

`kind` 为 `file`、`directory`、`symbolicLink`、`hardLink` 或 `other`。`size` 为非负安全整数或 null；verified 普通文件必须有 size 和完整内容的 64 位小写十六进制 SHA-256。目录固定 size=0、sha256=null；链接与特殊条目为 unverified，不能进入同内容组。当前扫描必须完整枚举才能成功，故发送 `listingComplete=true`；内容未验证仍可使结果 partial。[读取格式、只读边界和限额](../usage.md#archives)

结果结构为：

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

每侧每个输入条目必须恰好覆盖一次；双侧非空时必须同路径，不允许双 null。状态按顺序判定：任一存在条目 unverified → `unknown`；否则单边 → `removed`/`added`；类型不同 → `typeChanged`；verified 普通文件按 size + SHA-256 → `same`/`changed`。双方目录先视为 same，再从最深处向上汇总：任一子项 unknown → unknown，否则任一子项非 same → changed，双方空目录 → same。若提供不完整 listing，不能把对侧未找到的路径判定为确定增加或删除。

`sameContentGroups` 按 verified 普通文件的 size + SHA-256 分组，左右均非空且至少有两个不同路径；每组必须包括该摘要与大小的全部成员。只返回左右 ID 列表，不生成笛卡尔积；同路径的一对相同文件不单独成组。组表示相同内容，不推断唯一重命名或移动。宿主会独立验证覆盖、分类、父目录汇总与分组完整性，且只展示当前 catalog 中的条目；unknown 结果必须为 partial。压缩方式、时间和权限元数据不参与当前内容相等判断。

### `crossdiff.git-tree/1`

Git 0.1.0 需要 0.15.0 的 Git 宿主能力；实验协议仍为 v1，旧宿主不会因协议号相同就认识新类型。清单声明 `inputKind: "gitRepository"`、`resultView: "gitTree"` 与 `supportedModes: ["pairwise"]`。宿主把提交来源解析为固定哈希，或捕获暂存区／工作区快照；每侧 `content` 显式说明来源。下面是提交来源：

```json
{
  "source": "commit",
  "snapshot": "commit:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "emptyBaseline": false,
  "entries": [
    {"path": "Sources/Main.swift", "objectID": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "mode": "100644"},
    {"path": "bin/run.sh", "objectID": "cccccccccccccccccccccccccccccccccccccccc", "mode": "100755"}
  ]
}
```

`source` 为 `commit`、`index` 或 `workingTree`。`snapshot` 是宿主提供的非空快照身份，最多 256 UTF-8 字节，不含 ASCII 控制字符；它是数据身份，不是 revision、Git 命令或发布者签名。`commit` 仅在真实提交来源时为 40 或 64 位小写十六进制哈希。本地状态不能借用 HEAD 的哈希冒充提交：

```json
{
  "source": "index",
  "snapshot": "index:host-generated-fingerprint",
  "commit": null,
  "emptyBaseline": false,
  "entries": [{"path": "README.md", "objectID": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "mode": "100644"}]
}
```

工作区使用 `source: "workingTree"` 及自己的快照身份；暂存区和工作区均要求 `commit: null`、`emptyBaseline: false`。尚无首次提交时，宿主可把 HEAD 表达为明确的空基准：`source: "commit"`、`commit: null`、`emptyBaseline: true`，且 `entries: []`；绝不生成假提交哈希。其他提交来源必须带真实哈希、`emptyBaseline: false`。

旧版 `{commit, entries}` 输入仍可使用，规范化为 `source: "commit"` 和 `snapshot: "commit:<OID>"`。新格式必须同时具备上面五个字段，不接受未知内容元数据。所有条目 `objectID` 仍为 40 或 64 位小写十六进制字符串，同一次比较保持单一 Git 对象格式；空快照没有条目时不凭空推断格式。工作区内容 ID 是实际 Git blob 标识，不代表将对象写入了原仓库。

宿主按完整文件对／重命名单元分批，每次 helper 请求最多 128 个文件对、每侧最多 128 个条目；这只是传输批次边界，**不是仓库文件数上限**。条目包含文件、符号链接和子模块，目录由路径隐式组成。`mode` 为 `100644`（普通文件）、`100755`（可执行文件）、`120000`（符号链接）或 `160000`（子模块）。宿主不跟随链接、不初始化子模块。提交树始终保持提交内容；未提交变化仅在明确选择暂存区或工作区时进入对应快照，未跟踪文件遵循用户选项。

路径最多 4096 UTF-8 字节、128 层，无绝对路径、空段、`.`、`..` 或 NUL；文件不能同时成为另一个条目的父目录。**路径按原始 UTF-8 字节区分**，不能像 Archive 契约一样进行 NFC 合并。有效文件名中的制表符、换行和反斜线保留为数据。当前宿主对非 UTF-8 Git 路径明确失败，不生成有遗漏的成功结果。

唯一可用的 `options` 字段为 `renameHints`，缺省为空数组：

```json
{"renameHints": [{"left": "old/name.swift", "right": "new/name.swift"}]}
```

提示来自宿主的 Git 重命名检测。每项必须是不同路径间、类型兼容的一对一删除／新增配对；左路径必须只存在于左树，右路径只存在于右树，不能重复使用。重命名阈值、共同祖先基准和引用选择由宿主处理，不是插件可执行的 Git 参数。脚本不得凭空补充无宿主证据的重命名。涉及暂存区或工作区时，当前宿主只提供内容完全一致的重命名提示；相似度阈值与共同祖先比较仅适用于两个提交来源。

结果 payload 为：

```json
{
  "rows": [
    {"left": "old/name.swift", "right": "new/name.swift", "state": "renamed"},
    {"left": null, "right": "README.md", "state": "added"}
  ],
  "counts": {"unchanged": 0, "added": 1, "deleted": 0, "modified": 0, "renamed": 1, "typeChanged": 0},
  "snapshots": {
    "left": {"source": "index", "snapshot": "index:left-fingerprint", "commit": null, "emptyBaseline": false},
    "right": {"source": "workingTree", "snapshot": "working-tree:right-fingerprint", "commit": null, "emptyBaseline": false}
  }
}
```

每侧每个输入条目恰好覆盖一次；空侧使用 null，不能双 null。状态依次表示：有提示的异路径配对 `renamed`；单侧 `added`／`deleted`；同路径的文件／符号链接／子模块类型不同 `typeChanged`；同类型对象 ID 或模式不同 `modified`；两者均一致 `unchanged`。`100644` 与 `100755` 属于同类型，其权限变化为 `modified`。重命名可能同时包含内容修改，所选文件的正文差异由宿主独立展示。`counts` 必须恰好包含上述六个字段，并准确汇总实际行。

`snapshots` 必须恰好含 `left`、`right`，每侧准确回传请求规范化后的 `source`、`snapshot`、`commit`、`emptyBaseline`，无多余字段。快照身份按 UTF-8 字节匹配；缺失、错误类型、过期身份或把工作区说成提交均拒绝。

宿主先验证整个快照的全局配对：来源恰好覆盖一次、同路径的左右项不能拆成两个批次的假删除／新增、重命名两侧不能分离、文件与子路径不能冲突、Git 对象格式必须统一。然后逐批执行真实受限 helper，核对本批覆盖、快照身份、引用身份、分类、重命名证据与计数，任一不符则拒绝整个比较。

所有批次保留同一来源快照身份，各自使用独立 `runID`。单批请求 16 MiB、结果 8 MiB、helper envelope 32 MiB 与执行预算保持不变；128 对的批次大小包含 4096 字节路径最坏 JSON 转义的空间。**不存在把整个仓库序列化成一个 JSON 的总大小门槛，也没有仓库总文件数限制。**脚本看到的 `entries` 是本批完整配对的子集；`completed` 表示本批已完成，不能据此宣称整个仓库完成。空比较仍执行一个空批次。

宿主仅在全部批次通过后，按全局目录顺序汇总行、计数和双语总述。插件自己的 summary 描述单批；核验进度不等于可发布的部分结果。取消、过期或任何一批失败时不返回部分成功，不接受用 `partial` 静默截断。`check-git-plugin.sh` 通过生产适配器和真实 helper 验证超过 50,000 个文件、完整重命名配对、最长转义路径以及批次中途取消。

脚本只获得选定来源快照的树元信息，不接收远程 URL、本机目录、凭据、完整提交历史或文件正文。宿主流式读取本地状态、按需解析选中文件并提供只读文本／Hex 详情，不检出分支、不修改本地仓库。裸仓库无暂存区或工作区，读取到本地状态变化时宿主要求刷新，不静默混用两次状态。远程下载与刷新是用户主动发起的宿主操作；第三方 JavaScript 不能请求任意 Git 命令、网络访问或文件读取。[契约验证](../../Sources/CrossDiffCore/GitPluginContract.swift)、[宿主适配器](../../Sources/CrossDiff/GitPluginComparison.swift)、[官方算法](../../Plugins/Official/Git/compare.js)与[使用限制](../usage.md#git)共同定义当前能力。

### `crossdiff.photography/1`

声明 `inputKind: "photoAnalysis"`、`resultView: "photography"`、`supportedModes: ["pairwise"]`。宿主读取用户授权的照片，在后台使用 Apple 颜色管理、RAW 解码和 OpenCV 4.12.0 现成转换／统计接口；脚本收到的 `content` 如下（数组长度见表，不能直接用省略数组作为有效请求）：

```json
{
  "red": [], "green": [], "blue": [], "lightness": [], "hue": [], "saturation": [],
  "neutralFraction": 0.25,
  "analyzedPixels": 4096,
  "sampled": false,
  "analysisSpace": "sRGB · SDR [0, 1] · HSL lightness · OpenCV 4.12.0"
}
```

| 字段 | 约束与含义 |
| --- | --- |
| `red`、`green`、`blue`、`lightness`、`saturation` | 各 256 个有限、0–1 的分箱占比；每个数组和为 1，容差 `0.0001`；L 是 HSL 明度，非物理亮度 |
| `hue` | 360 个色相分箱（0–360°），值均为有限的 0–1，占比仍除以全部有效像素；和为 `1 - neutralFraction`，容差相同 |
| `neutralFraction` | 有限的 0–1；HSL S < 0.02 的有效像素占比，这些像素不进入色相分布 |
| `analyzedPixels` | 1–100,000,000 的整数；当前宿主统计长边最多 4096，表示有效采样数，不一定是源像素数 |
| `sampled` | 布尔值；所选源区域因尺寸预算缩小时为 true |
| `analysisSpace` | 非空、最多 1024 UTF-8 字节，两侧必须完全一致；插件须尊重其色彩空间与值域含义 |

统计使用颜色管理后的浮点 sRGB SDR，值截至 0–1；完全透明／非有限样本排除，其余有效样本等权。`cvtColor(COLOR_RGB2HLS)` 输出通道顺序为 H、L、S，`calcHist` 直接提供各分布。色相总和不包含近中性色，不能重新归一化为 1。相同直方图不能证明照片像素相同，更不能证明作品质量相同。

宿主保留照片像素、绝对路径、EXIF 与 XMP 记录；脚本不接收这些数据或读取回调。输入 `name` 仍为文件名。当前选区改变会生成新任务，取消／过期结果不发布；命名区域和选定 XMP 路径由宿主会话持久化。第三方插件只能解释现有分布，不能通过 JSON 加载自己的原生库或增加未实现的图表。

结果 `schema` 为 `crossdiff.photography/1`，payload 示例：

```json
{"findings": [{"zhHans": "右侧低明度区域占比更高。", "en": "The right region has a higher low-lightness share."}]}
```

`findings` 为 0–8 项，每项 `zhHans`／`en` 均须非空、最多 2048 UTF-8 字节。宿主默认显示前 3 项，其余在分析信息中显示，沿用通用 `summary`／`diagnostics`／`status` 校验。图表直接来自宿主统计；文件曲线由 Apple ImageIO 解析实际 Adobe CRS 控制点，仅示意连接，不复现显影算法。插件不应声称从成片反推快门、Kelvin 色温、曝光调整或原作者的 HSL／曲线滑块。

每张源图最多 256 MiB／6400 万像素，预览长边 2048，ROI 统计长边 4096；RAW 支持取决于系统、机型和编码，不使用内嵌预览冒充完整解码。XMP 上限 8 MiB，需用户显式选择旁路文件，不自动读取同目录的其他文件。[摄影设计与语义](../architecture/photography-comparison.md)

### `crossdiff.api-exchange/1`

声明 `inputKind: "httpExchange"`、`resultView: "apiExchange"`、`supportedModes: ["pairwise"]`。每侧输入是用户选定的一次调用记录；HAR 含多条记录时由宿主提供选择界面。`content` 包含 `sections` 和双语 `diagnostics`。分区 ID 限定为 `request.summary`、`request.query`、`request.headers`、`request.body`、`response.summary`、`response.headers`、`response.body`。

每个分区有 `id`、双语 `label` 和 `fields`。每个字段有 `key`、`label`、`type`、`value`（字符串）、`sensitive`，可带原始名称 `name`。分区内 key 不重复。头／参数 key 为 `/转义名称/从0开始的同名序号`；头名称只做 ASCII 小写，查询参数保留原始编码。JSON 正文采用 RFC 6901 路径，根节点为 `""`，容器类型 `object`／`array` 值为空，不把孩子数量编码进父节点。叶子类型为 `string`、`number`、`bool`、`null`；数字以无损词法字符串传输，避免 Double 舍入。正文 `$state` 字段类型 `bodyState`，值为 `json`／`text`／`empty`／`missing`／`unsupported`，普通文本正文在 `$text` 字段中。

选项 `ignoreHeaders`、`ignoreJSONPointers` 为字符串数组，各最多 128 项，默认空。头规则不区分大小写，JSON Pointer 匹配节点及后代，作用于请求与响应；不能用规则把未记录正文伪装成一致。每侧记录最多 5,000 字段，单值最多 1 MiB，key／label 最多 16 KiB。完整输入限制见[使用指南](../usage.md#api)。

结果 payload 为 `{rows: [...], partial: false}`。每行包含唯一 `id`（最多32字节）、`section`、`path`、`label`、`left`／`right` 及对应 `leftType`／`rightType`、`state`、`sensitive`。某侧缺失用 null，不能用空字符串代替。state 为 `same`／`changed`／`added`／`removed`／`ignored`／`unknown`。最多 5,000 行，partial 要和外层 status 对应；官方算法还限制序列化结果大小。未记录／不支持正文使相关正文行保持 unknown；敏感标记只影响展示，真实值仍参与比较。[输出校验实现](../../Sources/CrossDiffCore/APIComparisonResult.swift)

## 6. 运行边界

### 受限 JavaScript

每个任务在独立 JavaScriptCore helper 进程执行，只向 JavaScript 注入 JSON 文本，不暴露 Foundation 对象、文件系统、网络、模块加载或子进程 API。没有 `require`、`fetch`、宿主对象桥接或异步任务协议。函数应同步返回可 JSON 序列化的结果。

默认 wall-time 为 15 秒，宿主可配置但不超过 60 秒；helper CPU 上限不超过 30 秒。stdin envelope 最多 32 MiB，结果最多 8 MiB，宿主默认 stderr 上限为 16 KiB。宿主在系统允许读取子进程统计时检查 512 MiB RSS；该检查是轮询预算，可能被系统拒绝，**不是硬内存隔离保证**。取消或超限会终止 helper，并丢弃结果。

这是**受限 JavaScript 运行时，不是操作系统沙箱**。进程隔离和没有 I/O API 不等于能够防御所有 JavaScriptCore 漏洞；宿主侧 PDFKit、归档与 Apple/OpenCV 图片解析、Apple AVFoundation/Accelerate 音频分析、AVFoundation/Core Image 视频读取与帧对照及独立 Olaf helper 也不在该 JavaScript worker 内；上面的 JavaScript 时限不包含这些原生阶段。不会静默改用完全信任运行方式。

### 完全信任原生可执行文件

原生插件通过 stdin 接收请求 JSON，读到 EOF；stdout 返回一个结果 JSON，不能混入日志。宿主不提供插件自选命令行参数。程序必须自行处理契约与错误；非零退出表示失败。

安装需要用户单独批准，该批准绑定当前可执行 payload 摘要。不同字节的新版本不能继承旧摘要批准。返回执行路径及运行前再次核对 bytes；运行前还检查有效代码签名。有效 ad-hoc 签名可证明相应代码完整性，但不等于验证发布者或完成 Apple 公证。

来源包的 `com.apple.quarantine` 会保留到提取的原生文件；宿主显式下载的原生包同样带来源标记。**带 quarantine 的原生程序在此预览版直接拒绝执行**，不会删除标记或绕过系统批准流程；安装审批本身不保证该程序可运行。本版没有 Gatekeeper 批准界面，也不提供关闭系统保护的工作流。

完全信任代码可能读取本机文件、联网或启动程序；清单、独立进程和宿主的只读结果视图不能限制这些行为。输出、运行时限和任务取消机制不构成对其自行创建进程或访问外部系统的权限控制。只在明确理解来源与行为时授权。

## 7. 安装与生命周期

本地选择、拖入 `.crossdiffplugin` 和任意 HTTPS 链接下载均进入同一包校验与安装预览。官方目录另设“下载并安装”：目录随应用内嵌、可离线查看；用户点击后，从固定版本的 GitHub Release 获取插件，核对完整包 SHA-256、大小、标识／版本和受限运行方式后直接安装，不再弹出第二次检查。此入口不能批准原生代码。HTTPS 不接受 URL 中的用户名/密码；重定向不能降为 HTTP。没有后台商店轮询或静默更新。下载失败或包无效不会替换已安装版本。

外部插件保存在用户数据目录的 `Plugins/` 下，默认是 `~/Library/Application Support/CrossDiff/Plugins/`；项目启动使用项目内 `CROSSDIFF_DATA_DIR`。外部安装不修改已签名应用包。预装插件在应用打包前装配，只能随应用更新；用户可以停用，或从当前列表移除并离线恢复。移除仅记录本地偏好，不改写签名应用包；跨重启、升级及 Base/Full 切换保持隐藏，显式恢复或重新安装才取消该状态。

安装保留不可变版本，原子提交元数据后才切换当前版本。同 ID、同版本却不同内容会拒绝。可以启用/停用、回退至上一版本或卸载外部插件。卸载原子移除注册，清理失败可能留下不再激活的文件；不会以这些残留文件恢复信任。会话保留来源路径与插件标识，缺失或停用时显示恢复入口。

运行任务固定已验证的插件版本；管理操作会使旧视图任务失效，并可能恢复或重新运行已打开会话的比较。包没有安装钩子，但不能据此承诺安装后绝不执行已有会话的算法。没有插件状态迁移、任意历史版本恢复或跨版本私有数据兼容承诺。

## 8. 验证与交付

```sh
bash scripts/tests/check-plugins-core.sh
bash scripts/tests/check-plugin-runtime.sh
bash scripts/tests/check-pdf.sh
bash scripts/tests/check-pdf-workflow.sh
bash scripts/tests/check-archive-plugin.sh
bash scripts/tests/check-git-core.sh
bash scripts/tests/check-git-plugin.sh
bash scripts/tests/check-git-workflow.sh
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

核心检查覆盖包/存储公开边界、失败持久化和 native 摘要信任；运行时检查使用真实 helper 与原生 fixture；PDF 检查覆盖算法、映射和源文件保持；Archive 插件检查通过真实子进程执行打包产物，并验证最大条目数、线性分组及非法输入；workflow 检查覆盖实际窗口。运行这些脚本时使用虚构文件与隔离目录，原生检查必须串行。`--build-only` 或超时不代表通过界面验收。

应用打包仍使用 `bash scripts/build-app.sh` 与 `codesign --verify --deep --strict dist/CrossDiff.app`。最低系统为 macOS 14；本项目使用 Swift 5 语言模式。当前本地构建使用 ad-hoc 签名，不是已公证发行包；Intel 与具体原生插件架构必须另行实测。分发插件前检查自身代码、依赖和资源的许可证与来源，并向用户披露实际能力及限制。

## 音频契约（0.11.0 新增）

官方示例为 [`Plugins/Official/Audio`](../../Plugins/Official/Audio/)。清单使用 `inputKind: audioAnalysis`、`resultView: audioTimeline`，只接受 `pairwise`，返回 `schema: crossdiff.audio/1`。旧宿主即使同为实验协议 v1，也不认识该领域；需要 0.11.0 或更新且提供音频视图的宿主。

输入为 `AudioSourceMetadata.pluginContent`：源 id、名称、时长、采样率、声道数、无损十进制字符串 frameCount、格式。`options` 必须包含 `analysisState`、`correspondences`、`diagnostics`，由 `AudioComparisonRequestOptions` 生成。自动指纹证据由宿主获得，包含双方源秒区间、时长比、方法、可选音高/原始分数和状态；不得把分数当正确概率。

`AudioRegion` 是源时间秒的半开区间 `[start, end)`，不能使用分析副本的帧号代替。最多 512 条对应，ID 唯一；允许乱序、重复以及一对多，不要求整个结果单调。`rateRatio = 右区间时长 / 左区间时长` 是这条映射的时间比例，不是用户 B 侧的试听速度，也不代表已估计任意变速。未估计音高时 `pitchSemitones` 必须为空。覆盖时长按每侧非 `rejected` 区间并集计算，不能把重复匹配重复计时。

`analysisState` 为 `idle`、`running`、`complete`、`partial`、`failed` 或 `cancelled`；只有 `complete` 对应结果信封 `status: completed`，其余状态为 `partial`。这表示分析流程状态，不代表内容相同或已找全所有对应。宿主输入诊断必须保留为结果诊断的前缀，插件可在其后追加说明；不能删除采样、预算或未知状态警告。

受限 JS 整理元数据差异与两侧非拒绝区间的覆盖并集。结果必须原样保留宿主对应数组、分析状态及诊断，宿主重新核对源范围、有限数、数量/字节预算、schema、任务 id 和覆盖。原始 PCM、波形和谱图不进入 JSON。宿主 Apple 分析与独立 Olaf C helper 属于受信的应用组件，不表示任意第三方插件获得了原生调用或通用文件句柄能力，也不等于操作系统沙箱。

契约源代码见 [`AudioComparison.swift`](../../Sources/CrossDiffCore/AudioComparison.swift)。检查入口：`bash scripts/tests/check-audio-plugin.sh`、`bash scripts/tests/check-audio-engine.sh`、`bash scripts/tests/check-audio-cache.sh`、`bash scripts/tests/check-audio-workflow.sh`。独立包用 `python3 scripts/package-audio-plugin.py`；两种宿主均带音频服务与 renderer。

<a id="video-contract"></a>

## 视频契约（0.14.0 新增）

官方示例为 [`Plugins/Official/Video`](../../Plugins/Official/Video/)。清单使用 `inputKind: videoAnalysis`、`resultView: videoTimeline`，仅接受 `pairwise`，结果为 `schema: crossdiff.video/1`。需要 0.14.0 或更新、提供视频能力的宿主；整体协议仍为 v1，旧宿主会拒绝不认识的输入与视图。

每侧 `VideoSourceMetadata.pluginContent` 只包含 `id`、`name`、`duration`、`width`、`height`、`nominalFrameRate`、`codec`、`hasAudio`、`isHDR`。`duration` 是 `{ "value": "6000", "timescale": 600 }` 形式的有理时间：值为无损十进制字符串，timescale 为正 Int32，时长大于 0 且不超过 24 小时。尺寸为方向变换后的显示尺寸，每轴 1–32768；名义帧率 0–1000，0 表示无法取得，不意味着固定帧率。`isHDR` 仅反映源传递函数标记。宿主不向脚本传文件路径、帧像素、PCM 或播放权限，未知元数据字段拒绝。

首版 `options` 必须为空。结果 payload 只有：

```json
{
  "metadataDifferences": ["duration", "codec"],
  "contentCompared": false
}
```

`metadataDifferences` 按 `duration`、`width`、`height`、`nominalFrameRate`、`codec`、`hasAudio`、`isHDR` 顺序列出真实不同的字段。宿主按原始输入重新核验；时长使用精确有理数比较，600/600 与 1000/1000 不算差异。额外字段、重复字段、遗漏／伪造差异以及 `contentCompared: true` 均拒绝。返回状态为 `completed` 只表示元数据整理完成，不能说明画面相同、整片已经对应或已完成质量分析。

播放、真实 PTS 逐帧、人工偏移、区域循环和 ROI 由原生宿主管理。暂停差异仅用于同像素尺寸、显式 Rec.709 SDR 标记的帧对；第三方脚本不能改变此限制。自动片段匹配和专业质量指标尚未开放。

契约实现见 [`VideoComparison.swift`](../../Sources/CrossDiffCore/VideoComparison.swift)。运行 `bash scripts/tests/check-video-plugin.sh` 验证 Core、真实 JavaScript 与 helper；`check-video-source.sh` 验证本机读取服务，`check-video-workflow.sh` 负责原生工作台。独立包通过 `python3 scripts/package-video-plugin.py` 生成；Full 预装，Base 可安装，两种宿主都包含原生视频能力。

## crossdiff.office/1

Office 0.1.0 需要 0.12.0 宿主；实验协议版本仍为 1，并不意味着旧宿主支持新增类型。每次请求比较**一个选中部分**，两侧 `kind` 必须相同：`word`、`spreadsheet` 或 `presentation`。

输入含 `sectionID`、`name` 与 `rows`。每行保存来源 `id`、从 1 开始的 `position`、`label`、`cells`。单元格包含从 1 开始的 `column`、`type`、可为 null 的原始字符串 `value`、`formula` 与 `format`。数值字符串禁止转成 JavaScript number；缺失缓存为 null，不是空字符串。格式记录供展示，不参与本版内容相等判断。

`options.keyColumns` 是最多 16 个不重复的列号，仅用于表格。输出 `payload.rows` 包含唯一 `id`、可为空的 `leftID/rightID`、`status`（`equal/modified/added/removed`）、`basis`（`exact/key/position/unmatched`）、`moved` 和 `ambiguous`。所有源行恰好覆盖一次。宿主验证来源、状态、关键列依据与覆盖，再根据自己保留的原文渲染；插件不能替换原文。先匹配完全相同行，再匹配关键列；重复或空键保持不确定。只有可信的 exact/key 对应参与相对顺序重排判定，位置配对不证明同一记录。

宿主对 ZIP/XML 资源、实体与外部关系施加限制。界面说明内容子集，并提供独立原文预览；不能把已提取内容相同表述为整个文档或视觉效果一致。参见[设计与边界](../architecture/office-comparison.md)和[官方实现](../../Plugins/Official/Office/)。

```sh
source scripts/project-env.sh
python3 scripts/package-office-plugin.py --output dist/Plugins/Office.crossdiffplugin
bash scripts/tests/check-office-plugin.sh
```

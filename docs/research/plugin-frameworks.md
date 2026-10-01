# CrossDiff 插件框架与原生宿主调研

调研日期：2026-10-01。状态：架构研究与验证计划，尚未实现或验证插件运行时。

本文使用三种标记：**事实**表示已查阅的项目文件或第一方资料；**推断**表示由事实得到的工程判断；**提案**表示待实现、测量和决策的设计。本文只借鉴 VS Code、Zotero 的机制，不建议复制它们的界面、品牌或整套运行时。

## 建议与当前边界

**提案：采用“原生宿主 + 可替换领域引擎 + 分层视图扩展”，先做进程间数据协议，另设 ExtensionKit 原生视图验证。** 宿主管理窗口、配对、标签、输入授权、任务取消、结果版本、会话与显式保存；插件贡献格式探测器、领域算法、结果模型和操作。Office、API、数据库、照片/RAW、音频、视频与模型拥有各自的结果 schema 和专业视图，不能统一退化为字符串 diff。

**已确认的新产品决策：** 首个真实插件是 PDF；远程能力首版只读；首版就支持第三方本地插件安装与真实第三方比较算法。信任策略已确定为**默认受限，保留用户显式选择的完全信任模式**。具体受限运行时、权限强制机制、完全信任入口的实现与发行验证仍需 spike；这些实现问题不再改变目标信任策略，也不能用声明式配置包代替真实算法扩展。

**事实：** 当前 CrossDiff 是 macOS 14+、Swift 5 语言模式的 Swift 包，主要能力为文本、文件夹、图片；公开说明目前无主动联网、账号和插件管理，发行包尚未采用 Developer ID 签名。许可证标记为 `AGPL-3.0-only`。这些是现有状态，不代表新架构已经落地。[Package.swift](../../Package.swift)、[README](../../README.md)、[NOTICE](../../NOTICE)、[产品规格](../specification.md)

**推断：** “应用内下载插件”需要明确新增联网边界；“比较默认本地执行”仍可以保留。数据库/API 的远程输入和用户启用的下载也应分别说明，不能沿用当前“应用不主动发送网络请求”的绝对表述。架构决定后应同步产品文档。

三个必须保留的区分：

- **独立进程不等于 sandbox。** 进程崩溃隔离、操作系统访问控制、协议权限代理是三层不同机制。
- **专业视图不等于任意代码注入。** 领域专用的原生渲染器可以与算法插件独立开发；完全未知的新 UI 则需要另一种扩展契约。
- **可下载不等于随意改写 `.app`。** 内容包、可执行插件、原生 UI app extension 的安装与验证路径不同。

## 可借鉴的已有机制

### VS Code：契约、按需激活和编辑器贡献

| 已核实事实 | 对 CrossDiff 的启发（提案） |
| --- | --- |
| Extension Host 有本地 Node.js、浏览器 Web Worker 和远程 Node.js 形态；扩展使用 `main` / `browser` 声明入口，用激活事件延迟加载。[Extension Host](https://code.visualstudio.com/api/advanced-topics/extension-host) | 把运行时选择与比较领域分开；主进程只读取 manifest，打开匹配输入才启动引擎。无需为了仿照该机制引入 Node.js。 |
| manifest 描述兼容宿主版本、贡献项、激活、依赖、扩展包等。[Extension Manifest](https://code.visualstudio.com/api/references/extension-manifest) | manifest 成为安装检查与发现入口；能力、UI 贡献、权限请求使用不同字段。|
| VSIX 可独立于 Marketplace 分发并从本地文件安装；包支持 `darwin-arm64`、`darwin-x64` 等目标。[Publishing Extensions](https://code.visualstudio.com/api/working-with-extensions/publishing-extension) | 在线目录和拖入本地插件包进入同一安装事务；平台包选择在执行前完成。CrossDiff 不需要兼容 VSIX 格式。 |
| Tree View 由扩展提供数据、宿主呈现；扩展通过已公开 API 贡献 UI，不能直接访问工作台 DOM。[Tree View API](https://code.visualstudio.com/api/extension-guides/tree-view)、[Capabilities Overview](https://code.visualstudio.com/api/extension-capabilities/overview) | 提供宿主所有的原生贡献点：导航树、检查器、菜单、动作、设置。插件不能获取任意 `NSWindow`、`NSView` 或 `Workspace` 对象。 |
| Custom Editor 将自定义文档模型与 Webview 表示分开；可编辑版本还需提供保存、撤销/重做、备份语义。[Custom Editor API](https://code.visualstudio.com/api/extension-guides/custom-editors) | 首批新领域默认只读。编辑、合并、导出必须显式声明并有领域事务模型，不能假设所有比较都能双向合并。 |
| Webview 需限制脚本、资源范围并使用 CSP；仅限制本地资源根目录并不足以形成完整保护。[Webview API](https://code.visualstudio.com/api/extension-guides/webview) | 若未来开放可选 Web UI，需独立审查桥接 API 和资源权限；它不是当前原生优先路线的默认视图实现。 |

**事实：** VS Code 官方明确说明 Extension Host 与 VS Code 本身具有相同权限，扩展能读写文件、联网、执行外部进程；安装时的发布者信任确认也不是按 API 执行的沙箱。[Extension runtime security](https://code.visualstudio.com/docs/configure/extensions/extension-runtime-security)

**推断：** VS Code 的 `capabilities`、贡献点和工作区信任不应直接被描述成 CrossDiff 所需的强制权限系统。CrossDiff 若要显示“此插件只能读两个输入文件”，必须有可验证的执行边界支持这个承诺。

### Zotero：离线安装、生命周期与兼容区间

**事实：** Zotero 支持下载 `.xpi` 后拖入插件窗口安装，同时明确提醒插件能完整访问 Zotero 和计算机。[Plugins for Zotero](https://www.zotero.org/support/plugins)

**事实：** Zotero 7 使用 manifest、最低/最高兼容版本、JSON 更新描述和安装/启用/关闭/卸载生命周期；更新描述可带 SHA-256，禁用时插件负责清理注册资源。它保留对平台内部的广泛访问。[Zotero 7 for Developers](https://www.zotero.org/support/dev/zotero_7_for_developers)

**事实：** Zotero 8 的开发文档继续列出平台升级带来的兼容调整，并建议优先使用正式菜单注册 API；对应插件禁用或卸载时，注册菜单可自动移除。[Zotero 8 for Developers](https://www.zotero.org/support/dev/zotero_8_for_developers)

**提案：** 借鉴“本地包即交付物”、明确兼容范围、启停生命周期和统一插件管理。由宿主持有所有菜单、命令、任务订阅的注册令牌，插件关闭时自动回收；不要继承对宿主内部对象的全面访问。SHA-256 用于完整性核对，发布者真实性还要靠可信签名与目录元数据。

## macOS 原生 UI 与分发的真实约束

### 跨进程原生 UI 是有官方路径的，但必须验证安装模型

**事实：** ExtensionFoundation 用于发现、启动和连接 app extension；ExtensionKit 可把扩展提供的 UI 纳入宿主。`EXHostViewController` 承载远程视图，SwiftUI 宿主可用 `NSViewControllerRepresentable` 包装它。[ExtensionFoundation](https://developer.apple.com/documentation/extensionfoundation)、[EXHostViewController](https://developer.apple.com/documentation/extensionkit/exhostviewcontroller)、[Including extension-based UI](https://developer.apple.com/documentation/extensionkit/including-extension-based-ui-in-your-interface)

**事实：** Apple 当前指南支持自定义扩展点、XPC 通信及限制扩展可来自宿主 bundle 或外部的 scope；程序化生成扩展点文件的流程从 macOS 26 等版本开始提供。官方也允许继续使用已有扩展点文件。因此不能把最新示例原样当成 macOS 14 的实施方案。[Adding support for app extensions](https://developer.apple.com/documentation/extensionfoundation/adding-support-for-app-extensions-to-your-app)

**事实：** 当前发现机制由系统维护；宿主外部的 app extension 默认禁用，设备所有者可批准或禁用。系统在应用安装/移除时记录扩展，再向宿主提供可用身份。Apple 的安全文档将 app extension 描述为随应用打包的签名可执行二进制。[Discovering app extensions](https://developer.apple.com/documentation/extensionfoundation/discovering-app-extensions-from-your-app)、[Supporting extensions](https://support.apple.com/guide/security/secabd3504cd/web)

**推断：** “下载任意 SwiftUI View 后直接装入宿主”不是这些 API 的保证。ExtensionKit 是具体的 app extension 打包、系统发现、用户启用、生命周期和场景通信方案。`.crossdiffplugin` 拖入安装要怎样包装、放置、登记包含扩展的应用，能否符合 macOS 14 的发现行为，仍需真实签名包验证。不能通过修改已签名宿主 bundle 或调用私有远程视图 API 来补洞。

**提案：** 首先验证真正独立的第三方原生 UI 扩展：一个表格视图和一个高频交互画布，覆盖焦点、中文输入法、菜单路由、复制、撤销、拖放、无障碍、缩放、深浅色、多窗口和崩溃恢复。验证成功后，独立原生 UI 才进入公开 SDK；失败时使用宿主领域渲染器，明确新视图类别需要宿主更新。

### 签名、公证、隔离不能混为一谈

| 已核实事实 | 设计结论（提案/推断） |
| --- | --- |
| Hardened Runtime 默认的 library validation 只允许 Apple 或与主可执行文件同 Team ID 的库/插件；加载其他发布者的库通常需要关闭此校验，且会触发额外 Gatekeeper 检查。[Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) | 第三方 dylib 不作为主窗口进程的默认插件机制。若以后必须承载，只在单独、权限受限的 helper 内讨论校验例外。 |
| Apple 公证要求有效 Developer ID 签名、适用的 Hardened Runtime 等；隔离属性存在的下载插件受公证/用户批准流程约束。在宿主进程内加载的插件使用宿主 entitlement。[Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | 包签名、Apple 可执行代码签名、公证、操作系统用户批准分别记录和验证。应用自己的“允许插件”不能代替系统批准；不清除 quarantine 绕过流程。这里的 entitlement 继承描述不应套到独立 app extension。 |
| Apple 的签名指南反对签名后随意改写应用包；替换符合 designated requirement 的等价嵌套代码存在特定例外，不能推广为任意新插件可插入 bundle。[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/) | 已发布 `CrossDiff.app` 视为不可变。运行时安装进入应用外插件目录；预装变体在打包、由内到外签名和公证之前完成组合。 |
| App Sandbox 通过 entitlement 限制系统资源；XPC 可用于权限分离，普通进程启动本身不提供各自的限制边界。[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)、[Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html) | 每种运行时要说明哪些权限由 OS/runtime 强制执行，哪些只是宿主 API 策略。用 `Process` 启动的任意 native 二进制不能宣称受 manifest 限制。 |

**推断：** 当前 ad-hoc 开发包不足以验证正式下载体验；Developer ID、异发布者插件、quarantine、公证在线/离线行为必须进入专门发行验证。独立进程减少插件崩溃对宿主的影响，也避免把第三方库装入主进程，但不会自动解决下载执行、凭证访问或磁盘读取权限。

## 运行时选择与三种架构

### 运行时的分工

| 运行时 | 优点（工程推断） | 限制与适用边界 |
| --- | --- | --- |
| 语言中立进程 RPC | 可接 Swift、Rust、C/C++ 以及自带运行时的其他语言；大依赖按需安装；可终止、重启单个引擎 | IPC、数据移动、分发目标和资源配额需要设计；仅有进程隔离不限制文件/网络。适合 Office 解析、RAW、媒体、数据库驱动等重依赖。 |
| 嵌入 JavaScript | 易写规则和小型结构化比较器；macOS JavaScriptCore 可执行 JS 并暴露受控 native 对象。[JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) | JSC 不等于 Node.js 或浏览器环境；公开哪些桥接对象决定能力边界。放入主进程仍共享故障与资源风险。建议只在专门 worker 中试验，不成为所有格式的必选依赖。 |
| Wasm / WASI | Wasm 通过 import/export 与外部交互，Wasmtime 的 WASI 文件系统采用能力模型；可显式提供只读目录。[Wasmtime Security](https://docs.wasmtime.dev/security.html)、[WasiCtxBuilder](https://docs.wasmtime.dev/api/wasmtime_wasi/struct.WasiCtxBuilder.html) | 仍须审计 host imports、资源限制和 runtime 更新；不是 macOS UI 或任意原生依赖的通用宿主。GPU/媒体/已有 SDK 适配需实测。适合纯算法、结构化规范化、轻量解析器。 |
| native dylib / bundle | 直接调用平台框架、原生控件和 GPU，传参成本低 | 与宿主共享地址空间和崩溃风险，受 Team ID/library validation、架构与 ABI 约束。Swift ABI 稳定不等于任意插件接口长期稳定；独立更新的框架仍需 module stability/library evolution 设计。[Swift Library Evolution](https://www.swift.org/blog/library-evolution/)、[Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) |

**事实：** JSON-RPC 2.0 定义请求、响应、通知和错误的数据约定，传输无关。[JSON-RPC 2.0](https://www.jsonrpc.org/specification)

**提案：** 用 JSON-RPC 2.0 风格的控制消息作为首个 spike，另行定义消息 framing、版本协商、取消、流控和大数据传输。它不是完整插件协议；请求 ID 也不是任务版本。不要在 JSON 中反复 base64 整幅 RAW、音视频或张量。可选 XPC、管道、文件描述符、只读缓存工件等传输适配必须有独立权限与生命周期定义。

### 方案对比

| 方案 | UI 与算法边界 | 主要收益 | 主要代价 | 建议 |
| --- | --- | --- | --- | --- |
| A. 原生宿主领域视图 + 进程引擎协议 | 插件输出版本化领域数据；AppKit/SwiftUI 视图由官方模块随宿主发布；轻型 Wasm 为可选运行时 | 原生体验稳定；语言与算法不绑死；容易沿现有源码渐进迁移 | 完全新颖的视图类型要更新宿主；必须坦诚这是首阶段的第三方 UI 限制 | **主线推荐，立即做最小纵向验证** |
| B. A + ExtensionKit 原生 UI 插件 | 可由第三方提供独立进程的原生场景，与引擎共享领域契约 | 能覆盖独立专业 UI，减少中央视图模块瓶颈 | macOS 14 路径、系统发现、包含应用安装、焦点/输入法/动作路由与签名矩阵尚需实测 | **并行 spike，达标后成为高级扩展层** |
| C. 类 VS Code 脚本宿主 + Webview，自定义 UI 广泛开放 | JS/Wasm 算法或 RPC；自定义 HTML/CSS/JS UI | 第三方制作复杂视图门槛较低，UI 形态自由 | 引入另一套 UI、无障碍/文本交互/生命周期及网络资源管理；背离当前原生优先方向 | **保留备选，不作为默认路线** |

native dylib 不另列第四方案：它可用于同版本构建、同发布链的官方内部模块，但不应同时承担“未来任意第三方安装”和“宿主可靠性”的基础承诺。

## 推荐契约：共享工作流，不抹平领域语义

以下均为**提案**。

### 宿主与插件各自拥有的状态

- 宿主拥有输入选择、双侧配对、原始输入身份/版本、授权、插件管理、标签与会话恢复、显式保存和外部改动检测。
- 引擎拥有格式解析、领域语义、匹配/对齐、度量和结果索引。探测器只读少量已授权字节，不得在发现阶段执行任意全文件扫描。
- 视图拥有暂时性选择、缩放、过滤和播放位置；持久化时带自己的 schema 版本。结果工件与源文件分离，预览/规范化数据不得写回原文件。
- 编辑型插件返回可预览的事务/导出结果；宿主经用户动作提交，保留撤销与输入版本校验。未声明可编辑的类型不显示合并按钮。
- 远程首版只提供读取/快照能力，不注册远程写入、更新记录、DDL 或提交接口；数据库连接还应使用服务端只读账户/事务等真实限制。插件自己的“只读”标签不能代替服务端授权。

### 至少需要的协议

| 协议面 | 必须携带或保证 |
| --- | --- |
| `initialize` / `capabilities` | 插件 ID、实现版本、支持的协议范围、引擎/视图种类、领域 schema、可取消性、读/写能力、平台、运行时、限制 |
| `probe` / `open` | 输入句柄与范围授权、媒体类型、字节长度、快照/哈希或外部修改标识；不要向所有插件广播真实路径及内容 |
| `compare` / `progress` / `cancel` | 会话 ID、任务 ID、输入版本、选项版本、截止时间；进度单调与结果排序约定；取消后迟到结果不发布 |
| `queryResult` / `getArtifact` | 结果 ID、schema 版本、分页/瓦片/时间窗口、工件哈希、尺寸、格式、授权与失效时间 |
| `prepareEdit` / `export` | 只读预览、涉及输入版本、输出类型、显式提交路径；不允许直接覆盖输入 |
| `dispose` / `shutdown` | 释放句柄、文件、订阅和缓存；崩溃时宿主仍能回收资源，重开后有可恢复错误 |

每个结果还要记录引擎版本、算法/参数、解码/规范化方式、精度限制、是否近似、警告与输入来源映射，保证“没有发现差异”可解释。是否支持精确相等是领域能力，不是全局布尔值。

### 专业视图与独立 schema 的例子

| 领域 | 应保留的原生交互和结果类型（提案） |
| --- | --- |
| PDF（首个真实插件） | 页码、页面坐标、文本范围、版面元素、渲染工件与源 PDF 的映射；页面视觉和内容结构差异分开；第一条真实纵向流程必须覆盖安装、比较、专业页视图和会话恢复 |
| Office / 文档 | 页面/段落/表格/样式/修订的独立定位；版面与内容差异分开；保留原对象映射 |
| API / 数据库 | 请求/响应结构、字段类型、schema、主键匹配、行集合和有序结果的区别；凭证通过单独授权通道提供 |
| 照片 / RAW | 解码参数、色彩空间、位深、元数据、直方图、瓦片与配准；像素近似和原始字节相等分开 |
| 音频 / 视频 | 有理数时间基准、轨道、时间偏移、波形/频谱、帧差异与同步预览；取样结果不可冒充全媒体逐项验证 |
| 模型 | 先标明模型类型：3D 网格/场景与机器学习网络/权重不能混用一种模型 schema；分别考虑拓扑/材质或张量/参数/结构视图 |

底层共享的是可取消任务、导航、定位、工件管理和比较会话，不是统一的“每个领域先转换成文本”。首个 SDK 只公布经过两个真实领域验证过的公共层。

## 插件包、权限、升级和发行变体

以下均为**提案**，格式名仅作讨论占位，不是已承诺兼容格式。

### 一个安装入口，两种获取方式

应用内目录下载与本地拖入 `.crossdiffplugin` 进入相同流程：检查包格式和大小 → 解压到隔离暂存区 → 校验 manifest/路径/签名/哈希/平台/依赖 → 展示发布者、能力与有效权限 → 激活兼容版本 → 健康检查 → 原子更新活动版本指针。归档拒绝路径穿越、越界符号链接、重复条目、解压炸弹与未声明执行入口；不执行任意安装脚本。

不要把不可信 manifest 的 `publisher` 当成已验证发布者。目录元数据签名与包签名绑定插件 ID、版本、平台和内容摘要；Apple 签名与 Team ID 独立校验。本地包也执行相同检查。开发模式可另设明确标记的本地未签名插件入口，但不得伪装成已验证插件或悄悄放宽正常安装策略。

原生 UI app extension 若需额外包含应用或系统启用，安装器必须明确展示并接续系统流程；此处不能提前承诺“下载后无条件立即可用”。

### manifest 的最小信息

| 分类 | 内容 |
| --- | --- |
| 身份 | 稳定 ID、版本、已声明发布者、独立签名身份、源码/主页、许可证、第三方 notices |
| 兼容 | manifest schema、宿主版本范围、协议范围、结果与状态 schema、最低 macOS、`arm64`/`x86_64`/universal、运行时及依赖版本 |
| 贡献 | 输入探测、比较领域、算法、视图 ID/需要的宿主渲染器版本、设置与命令 ID、中文/英文标题 |
| 执行 | 相对入口、资源清单、包大小/摘要、资源预算、网络/文件/凭证/外部程序需求、实际强制执行方式 |
| 生命周期 | 状态版本、迁移支持、可否回滚、更新来源、依赖图与固定版本 |

宿主安装时验证 schema，启动后再握手；不兼容时拒绝执行并说明原因。不能只按应用 SemVer 猜测所有协议相容。原生依赖包含自己的架构和部署版本要求；Rosetta 不能替代 Intel 或 Apple 芯片的实际验证。

### 权限的执行位置

| 权限 | 期望约束 | 可作出的承诺 |
| --- | --- | --- |
| 文件 | 比较输入只读；输出进入独立工作目录；显式保存才提交目标文件 | 只有 OS sandbox 或受限 runtime/句柄代理确实阻止绕过时，才能称“只能访问授权输入” |
| 网络 | 默认关闭；API/DB 连接按目标授权；下载器与比较器分开 | 若 native worker 未隔离，manifest 中 `network: false` 只是声明，不是防火墙 |
| 凭证 | 仅目标服务和当前任务需要的凭证；不向插件继承整个环境或持久化密钥 | 使用代理连接或受限凭证；不能保证拿到明文凭证的恶意插件不会滥用它 |
| 执行/GPU/设备 | 外部程序、GPU、媒体设备分别声明 | 首批不开放任意 shell；GPU 和平台框架依赖需纳入 sandbox 与兼容验证 |

### 首版第三方插件的执行等级

首版必须交付第三方本地包安装、兼容检查、启用/禁用/卸载和可用 SDK，不能以“以后开放第三方”代替。**默认受限、显式完全信任模式是已确认的目标策略**；下表比较的是其实现等级，不是再次要求用户选择是否保留完全信任入口。受限运行时尚未落地，必须通过权限拒绝实验；实现受限能力失败时不得自动切换为完全信任执行。

| 等级 | 首版可提供的真实能力 | 执行边界与限制 |
| --- | --- | --- |
| `data` / `declarative` | 规则、格式映射、阈值、宿主已有算法参数、声明式菜单/检查器配置 | 宿主按 schema 解释，不执行包内任意代码；要限制解析复杂度和资源引用。不能把这种插件宣传成能发明任意新算法或全新专业 UI。 |
| `wasm` | 第三方算法、规范化和可移植解析器，通过固定 host imports 与已存在的原生视图交互 | runtime 校验、内存/时间限制、WASI 或 host API 能力授予必须先验证。可安装字节码不代表已解决原生平台依赖、JIT 签名或任意 UI。 |
| `trusted-native-process` | 用户显式选择完全信任后，运行第三方自带 native 引擎及依赖，可实现难以迁移到 Wasm 的专业格式/算法 | 进程隔离用于稳定性。除非另有实证的 OS sandbox，按用户权限执行，可绕过宿主 API 自行读写/联网。安装/启用时明确其完全信任范围；不称受限插件，也不绕过 macOS 的签名、批准和系统访问控制。 |
| `native-extension-ui`（待验证） | ExtensionKit 独立原生专业场景 | 需要独立 SDK、macOS 14 与当前系统的发现/启用/分发验证；不是前面三类入口自动获得的能力。 |

**提案：** PDF 先走完整插件包/注册/任务/结果/视图链路，避免做成特殊内建分支。用一个真实第三方测试包检验公开 SDK，不只验证官方包。若选择 Wasm 实现默认受限计算入口，必须完成可运行算法、权限强制与专业视图通信的 spike；仅有 manifest 安装器不满足“可用插件”。完全信任模式若采用 `trusted-native-process`，必须把它的权限事实写进用户可理解的安装说明，验证显式选择和 macOS 下载执行流程。当前 ad-hoc 发行状态不能充当已验证 Developer ID 公证生态，包层发布者签名也不能替代 Apple 签名。

### 回滚与版本锁定

保留上一个可用版本和完整安装事务记录；当前会话固定插件版本，新会话才切换。健康检查包括协议握手和无用户数据的最小任务；失败不替换活动版本。升级状态迁移先复制，旧版本不可读的迁移结果不得覆盖原状态。已撤销信任/存在严重问题的版本不能自动作为回滚目标；卸载插件不删除用户原文件，缓存与会话引用另行处理。

### base / full / photo / media / dev

使用同一宿主、同一插件协议、同一包仓库，通过固定版本组合清单生成不同交付物；不是五条独立代码分支。内建预装包参与同一插件注册与版本报告。

| 变体 | 建议预装范围 |
| --- | --- |
| `base` | 已有文本、文件夹、常规图片基础工作流；插件管理器与少量核心原生视图 |
| `full` | 发布时已验证、许可与依赖已核对的全部官方稳定能力；不是把整个第三方目录打包 |
| `photo` | base + 照片/RAW/元数据/色彩与相关专业视图 |
| `media` | base + 音频/视频解析、时间轴与相应引擎 |
| `dev` | base + 结构化数据、API、数据库以及相应 schema/表格视图 |

“Office 放入 full，是否另设 office 组合”留作产品决定，不在架构层硬编码。对很大的模型或可选解码资产，使用 manifest 中独立资产条目并显示下载大小；若某变体声称可离线使用某项能力，其必要引擎和资产必须随包交付。每个交付物都有可审计的组件版本、来源、许可证和校验清单。

## AGPL 与第三方生态

**事实：** 本项目现行许可证是 AGPL-3.0-only。[NOTICE](../../NOTICE)、[LICENSE](../../LICENSE)

**事实：** FSF 的 GPL FAQ 表述认为插件与宿主是否构成组合程序不仅取决于 `exec`、RPC 或动态链接，还涉及通信语义；该 FAQ 本身也说明组合边界最终是法律问题。[GNU GPL FAQ：插件](https://www.gnu.org/licenses/gpl-faq.en.html#GPLPlugins)、[GNU GPL FAQ：聚合](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)

**提案：** 在 SDK 发布前明确宿主、SDK、示例、协议文档、插件包和捆绑依赖各自的许可与源码提供方式。不要声称“跨进程自动免除 copyleft”，也不要未经逐项判断宣称所有第三方插件必然采用同一种许可证。`full` 的可再分发性按实际组件与组合方式核对；本技术报告不替代法律判断。

## 必须完成的最小验证

| 验证 | 最小实验 | 通过条件 / 未通过时动作 |
| --- | --- | --- |
| PDF 首个真实插件 | 通过正式插件包安装 PDF 引擎，在独立页面专业视图中显示结果与源坐标；禁用、重启、恢复会话 | 不依赖绕过公开 SDK 的官方专用分支；解释文本、页面和渲染差异的边界，失败不显示“相同” |
| 第三方 SDK/runtime | 使用公开文档独立制作一个第三方包，实际运行所选 data/Wasm/native 等级的一种有意义比较能力 | 从本地安装到显示结果完整可用；可禁用/卸载/升级；运行时与视图能力限制明确，不用空包安装成功代替插件可用 |
| 进程协议 | PDF 引擎之外，再用另一实现语言提供小型表格或瓦片图像引擎；模拟崩溃、超时和乱序响应 | 宿主继续可交互，取消能回收 worker，过期结果不覆盖新任务；测量首屏、IPC 字节量和峰值内存后再决定传输优化 |
| 权限 | 恶意测试引擎尝试读未授权文件、写输入、联网和启动子进程 | 由声明的 OS/runtime 边界实际拒绝；未达标不得宣传 sandbox 或开放对应不可信 native 模式 |
| 远程只读 | API/数据库连接读取快照，对写入/更新/DDL 操作测试拒绝路径 | 无宿主远程写接口，服务端凭证权限符合只读范围；不把可读写凭证交给任意 native 插件后宣称只读受限 |
| ExtensionKit UI | 独立发布者构建原生表格/画布扩展，macOS 14 与当前系统分别安装、启用、打开、多窗口、崩溃恢复 | 不改宿主 bundle、不依赖私有 API；焦点/输入法/菜单/无障碍正常；不通过则方案 A 继续且说明视图类别限制 |
| 下载与签名 | 正确签名、篡改、不同 Team ID、不兼容架构、缺依赖、带 quarantine、公证失败/离线等包 | 能区分应用信任和系统批准；所有失败保持旧版本可用；不通过不发布“一键安装”承诺 |
| 升级回滚 | 活动会话期间升级，迁移中断、磁盘不足、崩溃、回退旧版本 | 原会话和源文件不丢失；活动版本指针/状态目录一致；重启后事务可恢复 |
| 领域保真 | Office、RAW、音视频和模型各选小型基准集，检查定位、近似提示与原始输入保留 | 不把解析失败/采样遗漏显示为相同；报告明确算法、参数与限制 |
| 发行组合 | 生成 base 与一个专业变体，在无开发依赖的干净环境安装 | base 体积/启动不受重型插件拖累；专业包具备宣称的离线能力；两者会话及插件兼容 |

本次只完成资料核对和设计分析，没有运行上述 spike，没有验证签名/公证或 macOS 14 的第三方 ExtensionKit 安装行为，也没有安装任何运行时或修改应用代码。官方网页会继续更新，实施前应固定 SDK、工具链、运行时与文档对应版本。

# “对比一切”的领域模型与迁移接缝研究

调研日期：2026-10-01。范围：当前 CrossDiff 工作区的只读代码审计、官方资料核验与框架契约建议。本文是研究提案，不代表已经实现插件、三方合并、N 方比较、远程连接或以下专业格式；没有修改产品源码、安装依赖或操作 Git。

## 结论与事实边界

**建议保留现有文本、文件夹、图片算法，通过输入身份、比较拓扑、类型化结果与能力注册把它们接入框架。** “任意 N 个对象”描述会话和任务调度能力；不同领域仍应声明自己的匹配方法、结果精度和可执行操作。不能把现有 `left/right` 改成数组，就宣称已支持通用 N 方合并。

本文用 **事实** 标记从当前源码或主来源可验证的行为，用 **提案** 标记推荐设计，用 **推论** 标记由这些事实得到的约束。既有能力与计划能力分别说明；专业格式解析器、计算引擎、可写回能力都需要独立验收。

## 1. 当前项目真正需要迁移的位置

以下是工作区源码事实；链接定位到文件，表中符号便于后续代码移动后继续检索。

| 接缝 | 已核验事实 | 建议的最小迁移 |
| --- | --- | --- |
| 构建与平台 | [Package.swift](../../Package.swift) 定义 macOS 14、Swift 5 语言模式；App 依赖 `CrossDiffCore`；当前没有插件 SDK、运行时或外部依赖目标。 | 先增加纯数据/协议边界，再决定是否拆独立 SDK target。不要为了插件先迁移原生窗口或重写全部算法。 |
| 类型与方向 | [Workspace.swift](../../Sources/CrossDiff/Workspace.swift) 的 `ComparisonKind` 仅有 text/folder/image；`Side` 仅有 left/right。`ReplacementScope` 同样是 left/right/both。 | 宿主改用稳定 `ComparatorID` 与 `InputID`；旧 `Side` 留在双侧文本适配器内部，避免破坏撤销、IME 和合并。 |
| 会话状态 | 同文件 `ComparisonSession` 固定持有 left/right `StoredTextSide`、`TextDiffResult?`、双侧编辑器、搜索与差异状态；图片模型缓存也挂在这里。 | 新宿主会话只管输入、拓扑、选择、生命周期与插件状态。现有文本状态整体封装为内置文本会话，图片状态保留为独立适配器。 |
| 持久化 | [TextFileIO.swift](../../Sources/CrossDiffCore/TextFileIO.swift) 的 `StoredComparison` 是 kind + left/right；`SessionFile` 直接读写该数组，没有顶层 schema 版本。图片和文件夹目前也借 `StoredTextSide.path` 存路径。 | 增加版本化 envelope 和输入列表迁移器。旧 kind 映射为内置比较器 ID，旧两侧映射为稳定输入 ID；读到未知插件仍保留记录，不能像当前未知 kind 一样跳过后丢失。 |
| 打开与配对 | `WorkspaceStore.candidate` 根据文件夹、UTType image、扩展名判断；PDF/Office 显式拒绝，余项落到 text。`accept` 的两项同类型可自动配对；`PendingPair`、`openPairs` 和 [PairingView](../../Sources/CrossDiff/CrossDiffApp.swift) 都只表达两侧。 | 将“来源选择”与“比较器探测”分开；新增拓扑选择与 base 角色分配。保留用户已习惯的多项明确配对打开多个标签页，另提供创建单个 N 输入会话的入口。 |
| 原生界面 | [CrossDiffApp.swift](../../Sources/CrossDiff/CrossDiffApp.swift) 的 `WorkspaceView` 按 kind switch；文本视图硬编码两个 pane。 | 宿主按结果族/比较器注册选择原生呈现器；已有双栏作为默认 pairwise renderer。N 输入使用对象列表、摘要矩阵和选定对的详细视图，不强塞 N 个窄栏。 |
| 原生菜单 | [NativeMenuController.swift](../../Sources/CrossDiff/NativeMenuController.swift) 固定三种比较类型，`canEditComparison` 判断 kind == text；查找、保存、合并均直接路由到旧会话。 | 命令声明能力并按当前窗口、当前输入、结果选择和焦点验证；继续保留原生 responder chain，插件不能直接改全局菜单或抢后台编辑焦点。 |
| 文本算法 | [TextDiff.swift](../../Sources/CrossDiffCore/TextDiff.swift) 的 `TextDiffEngine.compareCancellable`、`DiffRow`、`DiffHunk` 和合并接口均为两侧；使用 UTF-16 范围，有取消和简化结果标记。 | 原样保留为 pairwise 算法。新 result adapter 把左右范围关联到 InputID；三方文本另编排 base→ours / base→theirs 并做重叠修改与冲突判断。 |
| 本地文件夹 | [FolderComparison.swift](../../Sources/CrossDiffCore/FolderComparison.swift) 使用本地 URL、Darwin 文件身份、digest、双根目录及 `toRight` 复制方向；复制计划有重新核对。 | 保留本地扫描/复制适配器。远端另做 provider 和快照/条件写契约，不能把远程 URL 填进本地 inode/path 逻辑。 |
| 图片流水线 | [ImageComparisonModel.swift](../../Sources/CrossDiff/ImageComparisonModel.swift)、[ImageComparisonRenderer.swift](../../Sources/CrossDiff/ImageComparisonRenderer.swift)、[ImageTransformGeometry.swift](../../Sources/CrossDiff/ImageTransformGeometry.swift) 已分开状态、解码渲染和变换几何，但输入和输出仍是两图、CGImage、有界 sRGB 预览。 | 保留为内置图像比较器；SDK 传图像描述/瓦片句柄而非 CGImage 对象。高级 RAW/HDR 可有另一条高精度计算管线，不能把 8 位预览当成无损原始数据。 |
| 可复用的可靠性 | [TextFileIO.swift](../../Sources/CrossDiffCore/TextFileIO.swift) 有外部修改签名检查；[SessionPersistence.swift](../../Sources/CrossDiffCore/SessionPersistence.swift) 串行落盘；现有模型发布后台结果前检查取消与版本。 | 这些约束提升为所有比较器的公共契约，而非抽象过程中删除的“旧实现细节”。 |

## 2. 提案：统一身份、拓扑与结果 envelope

### 输入不是“左侧字符串”

建议每个输入至少包含：`InputID`、用户显示名、`ProviderID`、不含凭据的资源引用、不可变 `SnapshotID`、内容类型及可用读取能力。一次结果固定引用它实际读取的快照；缓存键包含输入快照、比较器版本、规范化配置和变换配方。

资源可以是临时文本、本地文件、目录、远端目录快照、数据库只读快照、捕获的响应、媒体片段或模型及其伴随权重。输入的顺序是视图状态；`base/ours/theirs` 是语义角色；来源连接和凭据是宿主管理的资源权限。这三者不要合并成一个 `Side` 枚举。

### 两方、有 base 的三方、无 base 的 N 方分开表达

下面只是契约草案，不是已编译代码：

```swift
enum ComparisonTopology {
    case pair(first: InputID, second: InputID)
    case threeWay(base: InputID, ours: InputID, theirs: InputID)
    case nWay(inputs: [InputID], strategy: NWayStrategy)
}

enum NWayStrategy {
    case againstReference(InputID)
    case selectedPairs([InputPair])
    case allPairs
    case domainAlignment(AlignmentMethodID)
}
```

**提案：** 三个无共同祖先的文件属于 N 方比较，不显示“自动三方合并”。有 base 才能区分双方各自修改、相同修改、删除/修改冲突等。N 方全对比较有 `N × (N − 1) / 2` 对，应按选择懒调度、限制并发和缓存预算；“支持任意 N”不意味着一次把所有源与结果全装入内存，也不承诺任意领域都能 N 方写回。

### 类型化结果不等于一种万能 hunk

建议公共 envelope 保持小而稳定：

- `ResultID`、请求 generation、比较器 ID/版本、输入快照列表、topology。
- `Coverage`：完整、抽样、预览降采样、截断、部分失败；含实际已比较区间/页/元素数量。未比较部分不能显示“相同”。
- `Method`：字节精确、解码后精确、数值容差、结构匹配、视觉/统计近似；记录单位、精度、匹配依据和配置。
- `Summary`、诊断、分页游标或异步增量事件。
- `PayloadDescriptor`：结果族与带命名空间的 schema ID/版本，指向有界批次、瓦片或切片。宿主不能依赖任意 `Any`，也不应为了每个外部插件持续扩张一个包含所有领域细节的巨型枚举。
- `Actions`：显式可生成的操作计划；只读比较不隐含保存、复制、执行 SQL、重放请求、模型推理或媒体导出。

建议共享定位类型如下。每个 location 都绑定 InputID + SnapshotID；多个输入的映射可以缺失、不唯一或带置信度。

| Location 族 | 必需信息 |
| --- | --- |
| Text | UTF-16 range、原始/投影来源映射；不能用屏幕行号作为保存位置。 |
| Bytes | UInt64 offset + length；编码解释与字节地址分开。 |
| Tree / structured | 稳定节点 ID、路径/字段路径、节点匹配规则；显示路径不一定等于写入路径。 |
| Page | 页身份、页坐标系与框、文字范围、页面匹配；分页重排不能只靠页码。 |
| Cell | 表/工作表身份、行键或行号、列身份、公式/值/样式分量。 |
| Image | 源像素区域、图像尺寸、颜色空间、变换到比较坐标的映射；蒙版覆盖与 alpha 分开。 |
| Time | 有理时间 value/timescale、epoch、轨道/声道、时间范围、源→共同时间轴映射。 |
| Tensor / graph | 张量名或结构匹配 ID、dtype/shape/layout、轴切片、图节点/边/属性定位。 |

## 3. 提案：领域结果、原生视图与合并能力矩阵

表中的“可设计”均为未来能力，不能提前加入当前功能列表。三方列指有 base 的语义；仅能展示三个对象不等于支持三方合并。

| 领域与归属 | 类型化结果与原生视图 | 两方 / 三方 / N 方策略 | 合并或写入能力边界 |
| --- | --- | --- | --- |
| 文本、代码（基础） | TextAlignment、UTF16 hunks、ConflictSet；保留原生文本编辑器、差异导航、对应行对齐。 | 两方沿用；三方新增 base 冲突编排；N 方参考对象摘要+所选对详细视图。 | 当前两方块合并继续只改会话。三方输出独立结果缓冲区，未解决冲突明确标记，手动保存。 |
| 文件夹，本地/远程（基础） | TreeResult，按路径/匹配身份聚合每个 InputID 的存在性、类型、内容状态；树和属性矩阵。 | 两方沿用；三方区分增加/删除/修改；N 方路径 presence matrix，文件内容分派给相应比较器。 | 本地沿用可复核 CopyPlan；远端须声明原子替换/条件写/身份能力。不将复制等同完整同步，不自动推断重命名或删除。 |
| 普通图片（基础） | RasterComparison、几何配方、coverage mask、像素统计；并排/叠加/擦除/差异与四角变换。 | 两图主视图；N 图联络表、参考图叠加与差异矩阵。 | 当前只读；选图、输出对比报告与图像编辑/合成是不同能力。三张图片不自动构成可合并的三方图像。 |
| Hex/二进制（基础） | ByteAlignment，字节区间与偏移映射；虚拟化十六进制+ASCII，窗口化读取。 | 两方范围对齐；N 方参考字节或片段摘要。 | 首版只读。将来字节 patch 必须绑定目标 digest、长度变化和写入计划；不把二进制 patch 误称格式语义合并。 |
| PDF/文字文档/演示（Office 插件） | DocumentResult：结构片段、样式、页映射、页面图；文字与视觉双视图。 | 页面/段落对应；N 方章节/页摘要。 | PDF 首版只读报告；可编辑格式的结构 patch/导出另行验收。不能把抽取文字直接写回原 PDF 或承诺版式无损。 |
| 表格（Office 插件） | TableResult：工作表、列类型、行键、CellDelta 的公式/缓存值/样式分量；虚拟化网格与类型提示。 | 两方按键/位置匹配；三方按同一行键/列身份判冲突；N 方缺失/变化矩阵。 | 可设计单元格 patch 和新文件导出；公式重算、外部链接、宏与格式保真是独立能力，默认不执行。 |
| API / JSON / schema（插件） | StructuredResult + RequestSnapshot；树、字段路径、headers/status/body 分层。 | 两方结构比较；有同源 base 的文档才可三方结构合并；N 方环境/版本矩阵。 | 默认为捕获快照只读比较或配置文件 patch。发送/重放请求属于显式网络动作，不能由“比较”触发。 |
| 日志（插件） | EventAlignment、解析字段、时间区间、匹配置信度；时间线和原始行联动。 | 先冻结输入窗口；按事件键/序列/时间映射做 N 路对照。 | 只读；过滤和时钟偏移是可复现分析配方。抽样/丢行必须可见，不以合并日志假装恢复真实全局顺序。 |
| 抓包（插件） | CaptureResult：接口、packet/flow、协议字段、payload bytes、时间精度；事件表+结构树+hex。 | 包/流语义匹配与时间对齐；N 个观测点对照。 | 只读；不能默认重放流量、改变包或推断加密内容。导出选定包可另加显式能力。 |
| 数据库（插件） | SchemaResult + TableResult + SnapshotProvenance；schema 树、带主键网格、差异分页。 | 两个只读快照；有同源 base 和可靠行键才有三方行级冲突；N 方环境矩阵。 | 首版只读报告；将来 SQL/迁移脚本先生成、预览，再以宿主授权的事务计划执行；没有通用无风险自动 DB merge。 |
| 摄影/RAW/HDR（高级图片插件） | 原始元数据、解码配方、颜色描述、float/高位深瓦片、直方图与ROI统计；曝光/白平衡对照与图像视图。 | 相同解码配置下比较，可做不同配方对照；N 图接触表与统一 ROI。 | 保留原文件；输出配方/派生图另行声明。拍摄快门/ISO 元数据不是可恢复的图像“修改历史”。 |
| 音频（插件） | TimelineResult、声道映射、PCM窗口、波形/频谱、统计；同步播放与时间线。 | 按时间映射或手动锚点对齐；N 路比较只保留有限活动播放/解码。 | 默认只读；剪辑/混音/导出是独立渲染计划。不能把两个音轨差值当作可逆原始音频合并。 |
| 视频（插件） | 时间线、轨道、PTS、帧瓦片、图像差异；同步播放、擦除、关键差异时间点。 | 共同时间轴而非同一帧序号；N 路摘要与选定视角。 | 默认只读；转码/剪辑独立导出。没有共同剪辑项目和 base 时不承诺三方语义合并。 |
| ONNX / PyTorch / tensors（插件） | GraphResult + TensorCatalog + TensorDelta；节点/属性树、dtype/shape表、切片热图、分布与误差统计。 | 图与张量需分别匹配；N checkpoint 的同名/已确认映射摘要。 | 默认只读，不执行模型；选择、替换或平均权重都不是通用安全合并。任何新模型导出须独立格式验证及明确操作。 |

## 4. 官方来源核验：会影响契约的领域差异

### 4.1 PDF：文字一致与视觉一致分别回答

**事实：** PDFKit 的 `PDFPage` 分别提供文字/字符范围/选择和页面绘制、显示框、旋转能力。文字提取与页面渲染是不同 API 路径。[Apple PDFPage](https://developer.apple.com/documentation/PDFKit/PDFPage)

**提案：** DocumentResult 同时容纳文本片段和页面区域映射。文字层缺失时标记“无可提取文字”，可选 OCR 作为另一种有置信度的派生输入；未执行 OCR 时不能声称扫描件文字相同。视觉比较必须记录页匹配、裁切框、缩放与注释显示策略。页数相同、抽取字符串相同均不足以证明排版相同；段落抽取和二进制文件一致也不能相互替代。

### 4.2 表格：公式、存储结果与展示值不是一个值

**事实：** SpreadsheetML 单元格可以同时包含公式 `f` 和值 `v`，还带位置、类型与格式信息。计算链记录公式单元格的计算顺序，并非另一个显示字符串集合。[Microsoft Cell](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.spreadsheet.cell)、[Microsoft calculation chain](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-the-calculation-chain)

**提案：** `CellValue` 至少区分 blank/null、数值、文本、布尔、日期解释和错误；`CellFormula`、缓存结果、格式化显示值各自比较。声明是否进行了重算、使用什么引擎与时间；不执行公式也能比较其表达式，但不能据缓存值断言当前公式计算结果。行键不是默认存在；重复键、合并单元格、隐藏行、日期系统、浮点容差和工作表重命名都需要诊断，而非用文本行 diff 掩盖。

### 4.3 DB 与远端目录：先定义读到了哪个状态

**事实：** PostgreSQL Read Committed 的连续查询可见不同提交状态；Repeatable Read 的连续查询使用同一事务快照。导出/导入快照有时机及隔离级别限制。[PostgreSQL isolation](https://www.postgresql.org/docs/18/transaction-iso.html)、[SET TRANSACTION SNAPSHOT](https://www.postgresql.org/docs/18/sql-set-transaction.html)

**事实：** SQLite Online Backup API 能把活动数据库复制成一致快照，支持分步复制。[SQLite backup API](https://www.sqlite.org/backup.html)

**提案：** 结果记录数据库身份、schema版本、事务/导出快照信息和读取窗口；不可声称两个独立服务器在同一物理瞬间冻结。未知主键时可选择用户提供的键、稳定排序或多重集合语义；不能按读取顺序把任意行配在一起。远程目录同样声明“逐项可变扫描”或“provider版本化快照”；只有 provider 提供足够前置条件时才能承诺条件写入。连接失败和部分读取返回 partial coverage，不返回“相同”。

### 4.4 摄影：RAW 解码、颜色管理与统计配置属于比较方法

**事实：** `CIRAWFilter` 提供曝光、白平衡、降噪等配置，并允许选择受支持的解码器版本。Apple 明确说明：指定解码版本可维持视觉兼容，但不保证跨环境逐 bit 一致。[CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter?language=objc)、[decoderVersion](https://developer.apple.com/documentation/coreimage/cirawfilter/decoderversion)

**事实：** Core Image 默认在扩展线性 sRGB 工作色域处理，并在输入、工作空间和目标空间之间做颜色匹配。`CIAreaHistogram` 提供指定矩形区域的分量直方图，桶数与归一化配置可选。[workingColorSpace](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)、[Core Image histogram reference](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/)

**事实：** LibRaw 将原始传感器数据、颜色信息、处理参数、缩略图和快门/ISO/光圈等元数据分别提供。[LibRaw data structures](https://www.libraw.org/docs/API-datastruct.html)

**提案：** 基础图片维持当前有界 sRGB 预览；高级摄影插件另保留原始精度与分块访问，记录 decoder/version、白平衡、曝光补偿、去马赛克/降噪策略、输入配置文件、工作色域、传递函数、输出位深、alpha 与 ROI。跨颜色空间需明确转换后比较还是比较原始数值；缺失配置文件时显示采用的假定，不静默当成 sRGB。直方图必须带这些方法信息；不能混用 gamma 编码直方图与线性亮度直方图。

**推论：** 直方图丢失空间排列，因此完全相同的分布不证明两图相同。只比较缩略图也不证明 RAW 数据相同。高级管线优先评估原生 Core Image，LibRaw 作为另一个显式解码实现；相机支持、许可证、分发和差异基线需在选择依赖时单独核验，本文没有安装或承诺选定依赖。

### 4.5 快门信息不能从成片唯一恢复

**事实：** Image I/O 定义曝光时间元数据键，LibRaw 也暴露从文件读取的快门等字段。[Apple Exif exposure time](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifexposuretime)、[LibRaw metadata](https://www.libraw.org/docs/API-datastruct.html)

**推论：** 最终像素同时受场景照明、曝光时间、光圈、增益、白平衡与后期处理影响；多组输入可以得到相同成片，故不能仅凭成片唯一反推真实快门、ISO 或原始曝光过程。插件应显示“文件记录值 / 缺失 / 用户配方 / 估计”及来源，不把后期曝光滑块叫作修改拍摄快门，也不把可编辑元数据当成已验证拍摄事实。

### 4.6 ONNX 与 PyTorch：图结构、张量数据和执行代码分开

**事实：** ONNX 张量可将数据放在模型外部文件，描述相对位置、offset、length 等；大模型检查也有专门的路径用法。[ONNX External Data](https://onnx.ai/onnx/repo-docs/ExternalData.html)

**提案：** `ModelResourceSet` 包含模型清单及伴随资源快照。先读目录、图结构、dtype、shape与数据位置，再按切片读取。外部位置只在授权资源根内解析，处理规范化、符号链接、越界长度和缺失分片；不能把模型中的路径当作任意本机文件读取许可，也不自动联网补权重。结构一致但外部权重未读完的结果明确为 partial。

**事实：** `torch.load` 使用 unpickler；`weights_only=True` 缩小可执行对象范围，但官方仍列出拒绝服务、内存破坏等限制。`mmap` 可让 storage 在访问时延迟载入，`map_location` 控制设备映射。[torch.load](https://docs.pytorch.org/docs/stable/generated/torch.load.html)、[serialization security](https://docs.pytorch.org/docs/stable/notes/serialization)

**提案：** PyTorch 解析放在受限、可取消的辅助进程，显式 CPU 映射、显式 weights_only，不因失败自动退回不受限 pickle，不加载用户模块，不执行 forward。拒绝或另行处理需要执行的对象格式，不能仅按 `.pt/.pth` 扩展名断言安全。运行时版本与补丁策略另行评估；`weights_only` 不是进程隔离或资源限额的替代品。

**事实：** Safetensors 官方接口提供张量目录与 `get_slice` 部分读取。[Safetensors documentation](https://huggingface.co/docs/safetensors/index)

**提案：** 优先支持可直接结构化读取的 safetensors。所有格式共用惰性 TensorStore：catalog、元数据、切片读取、分块 reduction；不先把整个大张量复制成 Swift 数组或 UI 像素。精确位比较与数值容差比较分别显示；定义 dtype/shape 不同、NaN/Inf、正负零、稀疏表示、量化参数和缺失张量的规则。统计抽样附样本量和范围，不能用均值、余弦相似度或一个误差值代替完整相等判定。

### 4.7 音视频：时间轴是一等坐标

**事实：** AVFoundation 的资产由轨道组成，轨道段包含源时间到资产时间的映射；Core Media 用有理数 `CMTime` 表示时间，样本同时具有呈现时间与解码时间。[Apple Time and Media Representations](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/06_MediaRepresentations.html)

**提案：** 用呈现时间、轨道身份和时间映射定位差异，不以第 N 帧/第 N 个 buffer 代表同一时刻。区分手动 offset、速率漂移、剪切段映射与算法估计；显示无对应区间。音频的声道、采样率、延迟补偿，视频的方向、色域、动态范围与解码配方都要记录。预览重采样不改原始资源；按窗口/关键区间解码，先摘要再细看，播放同步与分析计算使用同一时钟模型。

### 4.8 API、日志与抓包：结构/时间来源要保留

**事实：** OpenAPI 描述接口与结构；JSON Pointer 定义 JSON 值的位置语法。pcapng 草案区分接口与数据包信息，并允许接口时间分辨率配置；此处引用的是草案，不冒充已发布 RFC。[OpenAPI specification](https://spec.openapis.org/oas/latest.html)、[RFC 6901](https://www.rfc-editor.org/rfc/rfc6901)、[pcapng draft](https://www.ietf.org/archive/id/draft-ietf-opsawg-pcapng-05.html)

**提案：** API schema、请求响应快照和真实网络动作分开；JSON 的键排序、数组顺序、数值类型和忽略字段是可见配置。日志与包保留原始字节/行定位、解析字段及时间来源；时间接近只是一种匹配依据，不自动证明是同一事件。来自多个主机/接口的时钟不默认为同步，TCP 重传等重复事件不应被不透明地删掉。

## 5. 提案：合并应是能力与计划，不是结果上的一个 Bool

建议至少区分以下动作，不让每个插件都实现一个含糊的 `merge(left, right)`：

| Action 能力 | 输出和前置条件 |
| --- | --- |
| `readOnly` | 只读选择、搜索、导航、导出报告。 |
| `textPatch` | 来源 snapshot、目标输入与 revision、UTF-16 范围、替换内容；进入目标独立撤销记录。 |
| `resourceCopyPlan` | 来源/目标身份、将新增/覆盖的项、执行前复核、provider 写入能力。 |
| `structuredPatchExport` | 受支持 schema 的操作、格式保真/校验结果、写新文件或供用户审阅的脚本。 |
| `derivedArtifactExport` | 图像配方、媒体时间线、报告等生成新产物，不声称还原或覆盖原件。 |
| `domainMerge` | 仅由显式支持的领域算法提供：base、输入快照、冲突集、解决选择与验证器。 |

比较器生成计划，宿主再根据目标权限、外部修改、用户意图与能力执行；计划不能偷渡插件声明之外的网络、代码执行、数据库修改或文件写入。现有手动保存、复制前预览、执行前重核和独立撤销应保留。

“本地运行、无自动上传”仍可作为核心承诺；用户主动启用的远程目录/API/DB provider 必须清楚展示连接对象与请求范围。未来有这类功能时，README 不能继续无条件写成“应用永不发出网络请求”。不需要账号系统来实现用户自行连接的远端资源。

## 6. 建议的渐进推进与验收门槛

1. **注册与包装现有三类比较器。** 建立 IDs、capabilities、result envelope、当前输入命令路由；两个输入时视图、算法、快捷键和文件行为不变。保留 Core/AppKit 分层，注册首批内置模块并不需要先允许运行任意第三方代码。
2. **版本化会话与 provider。** 旧 JSON 单向迁移可回退验证；插件缺失时保留输入/配置并显示不可用，不能静默丢数据。本地快照/资源读取先抽接口；Hex 作为检验大文件 range-read 与非文本结果的第四个内置域。
3. **N 输入工作区。** 先参考对象+按需 pairwise 与摘要矩阵；匹配和分页具有稳定身份。定义取消、背压、缓存预算与部分结果显示。不要先重写所有算法为 N 元递归函数。
4. **真正的三方文本合并。** 独立验证同改、无冲突修改、重叠冲突、删除/修改、换行/Unicode、过时 revision 与撤销保存；三方目录在稳定文本三方能力上编排。
5. **按结果族引入首批插件。** 文档/表格验证 Page+Cell，结构数据验证 Tree，摄影验证高精度瓦片与配方；不要用一套 text/HTML 预览强行替代全部原生交互。
6. **再接远程、媒体与张量。** 以 snapshot、timeline、lazy-range、受限辅助进程四条合同分别验收。每个领域声明支持的基数、格式子集、写入能力与精度，不做空泛的“所有格式均可无损比较”。

建议验收集：旧双侧核心/原生检查；旧会话迁移且输入内容不变；未知插件可恢复；第三输入不串用左/右编辑器和撤销；无 base 不能调用三方自动合并；所有来源 stale snapshot 被拒绝写回；部分/抽样结果不显示完整相等；页/单元格/时间/张量定位可往返到各自原始来源；网络 provider 不影响离线内置比较器；插件错误、取消和资源超限不使宿主失去响应。

## 7. 本次未做及需后续明确的决定

本文没有实现 SDK、加载器、插件市场、远程连接、第三方解析库、三方算法或任何新领域比较器；也没有宣称已验证外部插件隔离机制、格式写回保真、各种相机支持、数据库驱动或媒体解码覆盖。

进入研发前最有价值的技术决定是：首版第三方插件只提供类型化数据/操作声明还是也提供受信任原生视图；外部插件的进程与资源模型；首批 SDK 的三种结果族与兼容策略；N 输入界面的默认比较策略；哪些领域明确保持只读。这些决定可在包装既有算法的同时推进，不要求先冻结所有未来领域细节。

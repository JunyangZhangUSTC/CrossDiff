# 旧 Office 格式支持：方案、体积与实施边界

日期：2026-10-04。目标：`CrossDiff-office` / `zhangjy/office`。本轮仅调研、测量依赖与最小可运行性验证，没有修改应用功能，没有安装全局工具，没有访问用户文档，也没有下载完整 JRE 或 LibreOffice。

## 建议

支持 `.doc`、`.xls`、`.ppt` 可复用现有比较模型、匹配与 UI，主要增加旧格式读取层。以 Windows Office 97–2003 为第一批明确范围，更早的 Mac/Windows 格式需逐类验证，不能因后缀相同承诺全部覆盖。微软将这些格式列为二进制格式，与现有 OOXML 路径不同。[微软格式参考](https://learn.microsoft.com/office/compatibility/office-file-format-reference)

若三类一起提供，优先对 **Apache POI + 私有 Java 运行时的可选“旧版 Office 兼容组件”**做样本验证，直接读取内容而非先转存文档。已核实的上游 JAR 与 JRE 归档合计约 52.1 MB，最终组件下载大小及展开占用尚未测量。用户只在首次需要时主动下载，之后本地处理；UI 保持原生。此为工程建议，不是已经作出的实现决定。

若优先控制默认安装体积，可先验证 **Apple DOC 导入 + SheetJS XLS 读取**；两者不需要额外 Java 运行时，但不能覆盖 PPT，且 Apple DOC 的结构范围不能先视为与现有 DOCX 读取器等价。LibreOffice 可作为额外转换后端或未来版面预览引擎，转换结果必须标明来源。

## 当前实现与可以复用的部分

本地代码依据：[OfficeImport.swift](../../Sources/CrossDiffCore/OfficeImport.swift)、[OfficeComparison.swift](../../Sources/CrossDiffCore/OfficeComparison.swift)、[OfficeComparisonModel.swift](../../Sources/CrossDiff/OfficeComparisonModel.swift)、[OfficeComparisonView.swift](../../Sources/CrossDiff/OfficeComparisonView.swift)、[插件算法](../../Plugins/Official/Office/compare.js)、[当前设计](../architecture/office-comparison.md)。

- 宿主将 OOXML 读成 `OfficeDocument → OfficeSection → OfficeRow → OfficeCell`；JS 插件只处理选中部分的结构快照。
- Word 已有正文、表格与读取到的页眉页脚/脚注等部分；Excel 已有类型、值、公式、保存结果和原坐标；PowerPoint 已有播放顺序、文字、表格与备注。旧读取器应明确自己能提供哪些部分。
- 章节/工作表选择、Excel 跨行匹配与关键列、重复键歧义、搜索、字符高亮及原件预览可以继续使用。跨格式比较应允许 DOC↔DOCX、XLS↔XLSX、PPT↔PPTX，同一格式家族配对。
- 当前精确比较值和公式字符串；二进制数值或公式 token 转成字符串后可能与 OOXML 的原始表达不同。需要定义比较用的统一表示，同时保留来源证据，避免 `1`/`1.0`、日期制或公式表示差异形成假阳性。
- 当前多处明确拒绝旧后缀；导入器在现代后缀路径中把 CFB 文件头判为加密。新增时需要区别普通旧 OLE/CFB、加密包、真实格式和伪后缀，不能仅添加三个扩展名。

当前已有产物的只读测量：Office JS 包 **11,340 B**；`dist/CrossDiff.app` 内普通文件逻辑长度之和 **18,886,758 B（18.89 MB）**。办公读取和显示编译在宿主中，因此 11 KB 插件并不是完整办公功能的体积。以上不是发布 ZIP 大小，也不是磁盘分配块占用。

## 体积：实测、元数据与未知值

MB 为十进制。各行口径不同，不能直接当成最终 CrossDiff 安装包增量。

| 方案 | 已核实大小 | 尚未测量或范围限制 |
| --- | --- | --- |
| Apple `NSAttributedString` DOC 导入 | 依赖 macOS 自带框架，不需随包携带 DOC 引擎 | 新增桥接代码体积未知；只验证 API 存在，未对真实 DOC 测试结构保留 |
| SheetJS CE 0.20.3 full | 脚本 **951,904 B**；本地单文件 ZIP/DEFLATE level 9 **334,931 B** | 最终还需适配代码、许可等；只解决表格，不含 DOC/PPT |
| POI 5.5.1 二进制格式依赖 | 8 个 JAR 合计 **9,392,497 B** | JAR 本身已压缩；不是整个可运行组件 |
| Temurin 17.0.20.1+1 macOS ARM64 JRE | 官方 `.tar.gz` **42,722,113 B** | 没有解包；实际运行时安装占用、模块裁剪后的体积未知 |
| 上述 POI + JRE | 归档与 JAR 算术合计 **52,114,610 B（52.1 MB）** | 不是最终统一封装/签名后组件；安装展开占用更大但本次未测 |
| LibreOffice 26.8.0 macOS ARM64 | 官方完整 DMG **298,773,447 B（298.8 MB）** | 未下载展开；不等于 CrossDiff ZIP 增量或精简引擎大小 |
| 调用用户已有 LibreOffice | 无需在 CrossDiff 包内分发 LibreOffice 二进制 | 适配代码仍有增量；要求用户已有兼容安装，且转换结果有保真边界 |

### SheetJS：轻量 XLS 路线

官方 full standalone 支持 XLS；mini 版明确排除了 XLS，不能用更小的 mini 体积估算。旧中文编码支持应保留。库可以随组件本地分发，运行时不从 CDN 加载。[官方独立构建说明](https://docs.sheetjs.com/docs/getting-started/installation/standalone/)

官方说明可将 XLS 的 BIFF 公式 token 读成 A1 表达式，并且不自动计算公式结果。需保留公式、缓存、缺失值和错误值，验证共享/数组公式与跨表引用；公式字符串还有语言、前缀等表示规则。[公式文档](https://docs.sheetjs.com/docs/csf/features/formulae/)

本次从[官方固定版本脚本](https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js)下载并测量，SHA-256 为 `cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41`。gzip level 9 为 334,819 B，单文件 ZIP 为上表值，两者不能混称。

项目内最小探测使用系统 JavaScriptCore 加载此脚本，在内存中生成再读取 BIFF8：中文工作表名、中文列头和数值 3.5 均还原，版本为 0.20.3。说明无需 Node/Electron 即可运行基本路径；**不证明真实历史文件、公式、性能或生产隔离已经通过验收**。探测源码与结果保存在忽略的 `.build/research/legacy-office/`，未接入应用。许可为 Apache-2.0，分发需保留通知。[官方许可](https://docs.sheetjs.com/docs/miscellany/license/)

### Apple DOC 与 Quick Look

Apple 提供 `NSAttributedString.DocumentType.docFormat` 和 Microsoft Word 数据导入 API，可作为低体积 DOC 文本读取候选。[文档类型](https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype)、[DOC 导入](https://developer.apple.com/documentation/foundation/nsattributedstring/init(docformat:documentattributes:))

本机 AppKit SDK 也声明了转换可能有损的 `NSConvertedDocumentAttribute`。尚未实测其对复杂表格、页眉、脚注、修订的覆盖，不能把 attributed text 导入等同于完整 Word 结构 API。Apple 适配器应放在应用层/专用 helper，保持 `CrossDiffCore` 不依赖 AppKit。

Quick Look 提供原件预览，支持格式随系统变化；它不等于返回单元格/公式/幻灯片结构的解析器，不能用“系统能预览”替代内容比较读取层。[Apple Quick Look](https://developer.apple.com/documentation/quicklook)

### Apache POI：三类格式统一直读

HSSF 读取 XLS，HWPF 读取 DOC，HSLF 读取 PPT。使用二进制格式专用入口即可，无需引入 `poi-ooxml`、XMLBeans、OOXML schemas；普通读取也不需要 `log4j-core`。[官方组件表](https://poi.apache.org/components/index.html)

- HSSF 可分别提供公式表达式和缓存结果；公式读取不等于执行计算。[HSSFCell API](https://poi.apache.org/apidocs/dev/org/apache/poi/hssf/usermodel/HSSFCell.html)、[固定版本公式还原实现](https://github.com/apache/poi/blob/REL_5_5_1/poi/src/main/java/org/apache/poi/hssf/usermodel/HSSFCell.java)
- HWPF 有段落、表格、行和单元格模型，但官方明确说明其功能覆盖不完整。需要验证修订、嵌套表格和浮动对象，不能承诺 Word 完整保真。[官方范围](https://poi.apache.org/components/document/)
- HSLF 可读取幻灯片、文本、shape 与备注；还需适配阅读顺序、分组和母版占位符。内容结构与视觉渲染是两种目标。[幻灯片 API](https://poi.apache.org/apidocs/dev/org/apache/poi/hslf/usermodel/HSLFSlide.html)、[备注 API](https://poi.apache.org/apidocs/dev/org/apache/poi/hslf/usermodel/HSLFNotes.html)

以下是官方 POM 的常规依赖闭包与对应 JAR 的 HTTP 大小，不是类裁剪后的理论最小值：

| 构件 | 版本 | 字节 |
| --- | --- | ---: |
| poi | 5.5.1 | 3,006,527 |
| poi-scratchpad | 5.5.1 | 1,913,107 |
| commons-codec | 1.20.0 | 401,021 |
| commons-collections4 | 4.5.0 | 898,652 |
| commons-math3 | 3.6.1 | 2,213,560 |
| commons-io | 2.21.0 | 585,274 |
| SparseBitSet | 1.3 | 25,843 |
| log4j-api | 2.24.3 | 348,513 |

来源：[poi POM](https://repo.maven.apache.org/maven2/org/apache/poi/poi/5.5.1/poi-5.5.1.pom)、[scratchpad POM](https://repo.maven.apache.org/maven2/org/apache/poi/poi-scratchpad/5.5.1/poi-scratchpad-5.5.1.pom)。全部构件 URL 与测量清单存于 `.build/research/legacy-office/poi-size-manifest.json`。

JRE 大小来自 Temurin 官方发布资产元数据，固定文件为 [OpenJDK17U-jre_aarch64_mac_hotspot_17.0.20.1_1.tar.gz](https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jre_aarch64_mac_hotspot_17.0.20.1_1.tar.gz)。运行时可私有打包，无需用户全局安装 Java。[官方发布元数据](https://api.github.com/repos/adoptium/temurin17-binaries/releases/tags/jdk-17.0.20.1%2B1)

`jlink` 可以裁剪 Java 模块，但最终模块集合和体积需实测；POI 用到 `java.desktop` 等模块，不能套用只带 `java.base` 的极小示例。将 Java 编译为原生程序也不是未经验证即可承诺的小包捷径。[jlink 文档](https://docs.oracle.com/en/java/javase/17/docs/specs/man/jlink.html)、[POI 模块声明](https://github.com/apache/poi/blob/REL_5_5_1/poi/src/main/java9/module-info.java)

POI 为 Apache-2.0；Temurin 为 GPLv2 + Classpath Exception。固定版本分发还需核对随包许可证与通知，纳入依赖升级和安全修补流程。[Temurin FAQ](https://adoptium.net/docs/faq/)

### LibreOffice：兼容转换路线

LibreOffice 可在本地将 DOC/XLS/PPT 转为 OOXML，再交给现有导入器，也能输出 PDF 辅助预览。[官方过滤器](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

本次固定 ARM64 26.8.0 的[官方 DMG 元数据](https://download.documentfoundation.org/libreoffice/stable/26.8.0/mac/aarch64/LibreOffice_26.8.0_MacOS_aarch64.dmg.mirrorlist)给出 298,773,447 B；SHA-256 为 `8858d8058da4f862f47559486814e65efc27294da67c5e4bb56b006b1ee59f89`。未下载完整安装包。

`--headless` 是无界面运行模式，不会自动缩小交付包。LibreOfficeKit 是调用办公引擎的 API，不是只有几个头文件大小的独立转换引擎；本次未核实可直接采用的官方 macOS ARM64 精简引擎包。[CLI](https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html)、[LibreOfficeKit](https://docs.libreoffice.org/libreofficekit.html)

转换可能改变或遗漏修订、OLE、公式、表格、母版等信息，结果应标记“经转换”。尤其不能未经验证就把转换后的 Excel 值称为原始 XLS 的“保存结果”；官方加载重算设置对 Excel 列出的范围是 2007 及以后，不能由此推断旧 XLS 缓存一定不变。[转换限制](https://help.libreoffice.org/latest/en-US/text/shared/guide/ms_import_export_limitations.html)、[重算设置](https://help.libreoffice.org/latest/en-US/text/shared/optionen/01060900.html)

若采用这条路线，可优先验证调用用户已有 LibreOffice，避免首次就分发完整套件。使用独立用户配置、输入副本、每侧隔离输出和进程预算；不复用用户正在工作的会话。UNO 提供 `MacroExecutionMode` 与 `UpdateDocMode`，可设 `NEVER_EXECUTE`、`NO_UPDATE`，但这些配置以及无界面运行均不等同于 OS 沙箱或网络阻断，需要单独验证。[加载参数](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1document_1_1MediaDescriptor.html)

随包分发 LibreOffice 时需核对 MPL-2.0 和其各依赖许可，保留相应通知与源码获取安排。[官方许可](https://www.libreoffice.org/licenses/)

## 没有选为通用后端的轻量 C/C++ 库

- **libxls** 能提供 XLS 值、公式缓存及原始公式记录回调；源码的公式工具只 dump token，且不属于正式 reader 构建，不能直接替代现有“公式表达式＋保存结果”比较。补齐该能力会引入大量自写公式解析工作。469 KB 源码归档也不是最终库体积。[项目](https://github.com/libxls/libxls)、[公式工具](https://github.com/libxls/libxls/blob/dev/formulas/xlsformula.c)、[构建列表](https://github.com/libxls/libxls/blob/dev/Makefile.am)
- **libmwaw** 针对更早的格式，官方表中 Word 为 Mac v1–v5.1，PowerPoint 为 Mac v1–v4、Windows v2–v4/95，不能当作三类 Windows Office 97–2003 的统一引擎。[官方支持表](https://sourceforge.net/p/libmwaw/wiki/Home/)
- **librevenge** 是过滤器框架与输出接口，需要具体格式读取库，不单独解析三种格式。[官方说明](https://sourceforge.net/p/libwpd/wiki/librevenge/)
- **wv / antiword** 更偏旧 Word 转换或文本提取，不解决 XLS/PPT；结构完整性与维护情况均需额外评估。本项目不应为了小包将表格全部压平后仍声称完整办公比较。[wv 项目](https://wvware.sourceforge.net/)

## 需要增加的工程内容

1. 格式探测、旧格式读取器分派及三类结构适配；拆开 OLE/CFB 与加密判定。修正文件选择、路由、配对和错误信息中的旧格式拒绝。
2. 保留来源位置、类型、公式与保存结果；定义旧新混合比较中的数值/日期/公式统一表示。按能力显示未比较内容，读取失败不伪装成空文档成功。
3. 后台只读导入，取消、超时和输入/输出/内存预算；采用库的容器解析能力而非自写二进制格式。宏、外链和公式执行不属于比较动作。
4. 若选按需引擎：新增多文件组件协议、架构与宿主兼容版本、下载摘要/代码签名、原子安装、失败回滚、卸载和许可证资源。公共安装框架变更需与 `main` 协调，以提交合并传播。
5. 真实旧 Office 生成的样本与故障回归：中文、表格、修订、PPT 备注、Excel 公式与过期/缺失缓存、1900/1904 日期、隐藏/合并、重复行、旧新格式互比、加密/损坏/资源超限。既有测试中的 `legacy.doc` 是拒绝路径占位符，不是旧格式解析验收。

当前 [PluginPackage.swift](../../Sources/CrossDiffCore/PluginPackage.swift) 的包是单脚本或单 executable 的 JSON：总包 16 MiB、JS 2 MiB、原生 executable 8 MiB，无资源目录。官方目录仅下载受限 JS，而且 Office 请求已由宿主预解析。因此 **JRE/LibreOffice 不能直接塞进现有办公插件包**；放宽大小也不会自动得到依赖管理。宿主可参考现有音频 helper 的进程管理，但独立进程不自动等于安全沙箱。

当前 Base/Full 使用相同主程序与 helper，区别主要是预装 JS 集。若简单把大引擎链接或无条件捆入宿主，Base 也会增重；按需组件或按 edition 分发必须显式设计。[构建脚本](../../scripts/build-app.sh)

## 后续决策门槛

先用真实样本验证候选读取器是否达到现有办公内容比较范围，尤其 DOC 表格/修订、XLS 公式/缓存、PPT 页顺序/备注及旧新混比。通过后再实测最终组件下载、展开磁盘占用、首开时间、峰值内存与维护成本，决定轻量内置或按需安装。现有证据足以支持路线选择与依赖量级判断，尚不足以给出最终产品增量或完整兼容承诺。

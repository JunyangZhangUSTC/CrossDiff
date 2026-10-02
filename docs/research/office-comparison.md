# 办公文档比较：读取、呈现与行匹配

研究日期：2026-10-02。本文记录技术选型依据和建议，不代表已经交付的能力；实际支持范围以使用指南与验收记录为准。

## 建议路线

首版面向现代 **DOCX、XLSX、PPTX**，以受限读取的结构快照驱动原生比较界面。读取内容和展示原文分开：比较结果来自可验证的段落、单元格与幻灯片结构；原文可另用系统 Quick Look 辅助查看。旧版 DOC／XLS／PPT、加密文件与完整排版重建不混入首版承诺。

这是针对 CrossDiff 原生 macOS、本地只读、小规模插件分发的工程建议。ECMA-376 统一规定了 OOXML 的词汇、表示及包结构，但三个文档域仍各有模型，不能把 ZIP 中所有 XML 的文字简单拼接后称为完整办公比较。[ECMA-376](https://ecma-international.org/publications-and-standards/standards/ecma-376/)

## 现成方案与边界

| 方案 | 已核实的能力 | 对 CrossDiff 的意义 |
| --- | --- | --- |
| Apple `NSAttributedString` | macOS 的文档类型包括 `docFormat` 与 `officeOpenXML`；后者是 Office Open XML **文本**文档。 | 可验证 Word 文本导入，不是 Excel／PowerPoint 的统一解析器，也不能据此承诺 Word 原始分页一致。[Apple 文档类型](https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype) |
| Apple Quick Look | 官方列出 Office 文档预览；macOS 可将 `QLPreviewView` 嵌入界面，加载是异步的。 | 适合按需原文预览。已查文档没有提供办公语义树或可用于 diff 的逐段／逐页映射；不能把预览支持当作结构解析支持。预览失败应不影响已经完成的内容比较。[Quick Look](https://developer.apple.com/documentation/QuickLook)、[QLPreviewItem](https://developer.apple.com/documentation/QuickLookUI/QLPreviewItem)、[异步加载](https://developer.apple.com/documentation/quicklookui/qlpreviewview/previewitem) |
| CoreXLSX | Swift 编写，Apache-2.0，只读 XLSX，公开提供工作表、共享字符串、样式等模型；明确不支持旧 XLS。依赖 ZIPFoundation。 | 原生生态中可信的 XLSX 候选，但不覆盖 Word／PPT；采用前仍需验证共享公式、日期、资源上限与错误报告，不能因用了库就省略这些验收。[CoreXLSX 官方仓库](https://github.com/CoreOffice/CoreXLSX) |
| python-docx | Python 的 DOCX 文档模型；明确不读取 Word 2003 及以前的 DOC。 | 有成熟内容模型，适合独立验证样本与生成测试资料；交付到应用需要额外 Python 运行时。[官方文档](https://python-docx.readthedocs.io/en/stable/user/documents.html) |
| openpyxl | XLSX 读写；只读模式降低内存开销；可分别读取公式或上次保存的缓存值；**不计算公式**。 | 适合交叉验证表格导入结果；若作为产品依赖，需要连同 Python 运行时封装，且仍不能冒充 Excel 计算引擎。[读取选项](https://openpyxl.readthedocs.io/en/3.1/tutorial.html)、[公式边界](https://openpyxl.readthedocs.io/en/stable/simple_formulae.html) |
| python-pptx | 可读取 PPTX 的幻灯片、文本、图片、表格等；不支持旧 PPT，不覆盖格式全部功能。 | 可验证演示文稿结构，不是像素一致的 PowerPoint 渲染器；需要 Python。[项目说明](https://python-pptx.readthedocs.io/en/stable/)、[旧格式边界](https://python-pptx.readthedocs.io/en/stable/user/presentations.html) |
| Apache POI | Java 组件分别支持 XLS／XLSX、DOC／DOCX、PPT／PPTX；各模块能力并不完全相同，Word 支持有明确限制。 | 三种现代与旧格式的一体化候选；要付出 JVM 与多个 JAR 的分发、更新及隔离成本。[官方组件表](https://poi.apache.org/components/index.html) |
| LibreOffice | 可通过 `--headless`、`--convert-to` 转换文档，并指定独立用户配置。 | 若后续要求统一 PDF／页面渲染，可作为可选转换后端；不应为首版默认捆绑一整套办公应用。仍需验证字体、版式和转换错误，不能保证与原应用像素一致。[官方命令行文档](https://help.libreoffice.org/latest/en-GB/text/shared/guide/start_parameters.html) |
| Microsoft Open XML SDK | 微软维护的 .NET OOXML 工具，提供 Word、Excel、PowerPoint 的类型模型。 | 是可靠的结构与样例参考；产品采用它会新增 .NET 运行时，与现有 Swift 宿主的部署方式不同。[官方 SDK](https://learn.microsoft.com/en-us/office/open-xml/open-xml-sdk) |

上述部署成本是依赖结构带来的工程判断，未测量最终安装包大小。此次没有找到经验证、单个即可覆盖三类办公文件且提供高保真排版的 Apple 原生开源库；这不是声称此类库绝不存在。若不引入额外运行时，可以采用 Apple XML 解析器与受限 ZIP 读取，按规范实现**明确的内容子集**，并对未比较的格式／对象显示范围说明。

## 应当比较什么

### Word

正文应保留段落与表格边界，按块对齐后显示字符差异。页眉页脚、脚注、批注、修订、文本框、图片与版式是不同的比较维度：首版没读到的部分需要说明，不能显示“整个文档完全相同”。WordprocessingML 的正文包含段落、文本运行与文字；完整包还包含其他独立部件。[WordprocessingML 结构](https://learn.microsoft.com/en-us/office/open-xml/word/structure-of-a-wordprocessingml-document)

建议默认比较当前可见正文，遇到已有修订记录给出明确提示；不要把删除修订与现正文混为同一段文字。不能以段落编号充当页码，段落跨页是排版结果。

### Excel

单元格快照至少独立保留：源地址、类型、原始值、显示值（若可可靠解释）、公式、缓存值是否存在。共享字符串必须先解析索引；数值与日期需要结合类型／样式，不能仅看 XML 文本。[微软读取单元格示例](https://github.com/OfficeDev/open-xml-docs/blob/main/docs/spreadsheet/how-to-retrieve-the-values-of-cells-in-a-spreadsheet.md)

公式 `<f>` 与缓存结果 `<v>` 是两项证据。缓存来自上次计算，可能缺失；不重算时界面应标为“保存的结果”，不能当成当前实时结果。相同结果而公式改变、公式不变但缓存改变都应能识别。[微软公式说明](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-formulas)

以下行匹配是 **CrossDiff 设计建议**，不是上述读取库已实现的算法：

1. 工作表先按名称配对，保留左右选择入口。每行保留左右原行号，禁止用展示行号替代原始地址。
2. 默认先按类型化单元格序列寻找完全相同行，允许跨任意行号匹配。散列仅作索引，命中后核对实际内容；重复行按出现次数一对一消耗，不能把多个左行都配给同一个右行。
3. 提供“按关键列”模式，例如订单号／编号；用户明确选择一列或多列后，用键匹配并显示同一记录的字段变化。空键或重复键须标为有歧义，不能静默覆盖字典项。
4. 没有可靠键时，对剩余行做有上限的相似候选配对，保留匹配依据；证据不足就显示未配对，不把相似度当成身份事实。保留“按行号”作为最可解释的另一模式。
5. 区分“内容相同但位置变化”“已修改”“仅左侧／仅右侧”。单侧插入导致后续行号整体偏移，不应全部误报为移动；移动需要相对于配对序列识别。
6. 空白、空字符串、零、布尔值、错误值和无缓存公式不能统一压成空字符串。共享公式从属单元格不能因没有重复公式正文就被当作普通空值；不支持的公式形式应显式标注。

### PowerPoint

按演示文稿的幻灯片关系与列表顺序读取；不能按 `slide1.xml` 等 ZIP 路径排序推定播放顺序。默认比较幻灯片内文字与表格，可将内容相同的页识别为重排；左右保留真实页号。标题卡片用于导航，不能伪装成原始幻灯片缩略图。

母版、布局、主题、备注、图片、动画、音视频等是独立部件；纯文字相同并不等于整页视觉相同。首版未覆盖的维度需要列明。[PresentationML 结构](https://learn.microsoft.com/en-us/office/open-xml/presentation/structure-of-a-presentationml-document)

## 读取与验证约束

这些是本项目的建议性实现门槛：

- 仅访问用户选择的普通文件；ZIP 条目数量、解压累计字节、单部件长度、文本长度与处理时间均设上限。拒绝重复规范路径与逃逸包根目录的关系目标；不把包内容解压到用户目录。
- 只跟随包内允许的部件关系，不访问 `TargetMode="External"` 链接，不运行宏、OLE 对象或嵌入程序；压缩包扩展名与声明内容类型不一致时不盲目信任。
- XML 禁止外部实体解析，设置命名空间处理；Apple 明确说明启用 `shouldResolveExternalEntities` 可能触发网络或磁盘 I/O。除关闭该选项外，拒绝不需要的 DTD／实体结构并限制解析资源。[Apple XMLParser](https://developer.apple.com/documentation/foundation/xmlparser/shouldresolveexternalentities)
- 不把所有 XML 标签的本地名混为一谈；只接受声明支持的命名空间及内容类型。无法解释的 OOXML 变体、加密包、旧二进制格式给出可操作提示，不按空文档成功返回。
- 样本验收覆盖：中文／emoji、Word 表格与修订、PPT 重排与同标题不同正文、XLSX 重排／重复行／空键／多列键／共享字符串／内联字符串／1900 与 1904 日期制／共享与无缓存公式／合并单元格／隐藏内容、坏 XML／路径穿越／解压上限／取消。
- UI 验证以真实原生窗口为准：浅色、深色、中英文与最小宽度；错误和能力边界与差异摘要一起可见。原文预览只是辅助，结构结果不能依赖系统预览是否完成加载。

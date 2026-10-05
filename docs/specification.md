# CrossDiff 产品规格

初始范围与后续版本决策共同构成产品约束。当前能力、发行状态和已知边界以 [README](../README.md) 与 [更新记录](../CHANGELOG.md) 为准；下文按版本保留已经确认的产品决策。

## 2026-10-01 框架方向更新

后续研发以 [“对比一切”产品方向](product-vision.md)、[框架设计提案](architecture/compare-everything.md) 和 [路线图](roadmap.md) 为准。新增插件扩展、远程来源、二进制、三方合并与多对象比较的长期范围；首个真实插件为 PDF，远程初版只读，首版即支持第三方本地插件安装，默认受限并保留显式完全信任模式。

这一未来范围更新了下文初始规格中的“仅两侧比较”和先后顺序，但不表示这些功能已经实现；0.5.0 已交付下文记录的插件第一步，宿主增加用户主动触发的插件下载，比较仍在本机进行。技术路线中标记为待验证的运行时、专业视图和签名路径，须经过原型再形成稳定接口。

## Confirmed product decisions

CrossDiff is an open-source, local-first macOS comparison application without accounts or authentication. Prioritize native Mac interaction using SwiftUI and AppKit.

The most important workflow is pasting two temporary texts and seeing precise differences, including Chinese, punctuation and numbers. Code files and code directories follow. Deliver text, folders and images first; prioritize research-paper PDF comparison in the following milestone, then structured documents and spreadsheets.

- Use the focused two-column layout. The toolbar starts with **New…**: choose a comparison type, then choose the left and right inputs. **More Comparisons** opens plugin management. The macOS Compare menu also provides direct access to each type’s input page.
- Open allows multiple files and/or folders. Two compatible items can open directly. More than two items require explicit left/right pairing, creating separate comparison tabs. This is two-way comparison, not N-way diff.
- Both text sides are editable. Copy individual change blocks in either direction. Write to original files only on explicit save; preserve undo behavior and report outside modifications.
- Restore temporary comparisons locally on restart. Provide clear-history functionality.
- Compare folders recursively; allow selected file copying after previewing additions and overwrites. Full directory synchronization is deferred.
- Image comparison includes side-by-side, overlay and a draggable wipe; add a pixel difference view if practical in this milestone.

## Initial implementation and validation boundaries

Validate externally observable behavior at the text-diff/merge interface, filesystem comparison/copy interface, and saved-session round trip. These exercise the workflows above. Preserve Unicode text and original newlines; exclude algorithm internals and purely cosmetic layout from unit tests.

Use deterministic sample files and temporary directories. Original files are unchanged by comparison. Copy previews must be revalidated before execution. Large comparisons run away from the main thread, support cancellation where possible, and communicate practical limits rather than claiming unlimited input sizes.

## Delivery

Build a local `.app` bundle without installing globally. Provide reproducible build and test commands. An unsigned local development build is distinct from a signed/notarized public release. Record any unverified GUI interactions and incomplete first-milestone features honestly.

## 0.2 daily text workflow

- Align corresponding visual rows by default, including wrapped lines and missing rows. Display gaps must never enter source text, undo, copy, or saved sessions.
- Clicking a change or its gutter chooses the merge target without automatically merging it. Show the selected target in both panes and the footer.
- Search both raw sources with literal UTF-16 ranges, case-insensitive option, and native match navigation. Deleted preview-only text is not right-side source. Cap displayed matches with an explicit notice.
- Deletion review remains off by default and read-only. Standard copy excludes removed text; an explicit revision-copy action retains strikethrough in rich text and deletion/addition markers in plain text. Saving always writes raw source.
- Serialize background session writes; termination flushes the newest snapshot and clearing waits for older writes, so delayed writes cannot resurrect history.
- Keep development writes, temporary files, caches, test data and artifacts inside this repository. Use the project environment script and isolated development launcher.

## 0.3 原生菜单、替换与双语设置

- AppKit 管理窗口、工具栏、菜单与响应链，比较区和设置内容使用 SwiftUI。菜单按当前窗口及焦点验证可用性；设置或搜索输入框获得焦点后，编辑动作不得错误地落到后台比较文本。
- “编辑”菜单包含撤销（⌘Z）、重做（⇧⌘Z）、剪切／复制／粘贴（⌘X／⌘C／⌘V）、全选（⌘A）；“编辑 → 查找”包含查找（⌘F）、查找并替换（⌥⌘F）、下一个／上一个匹配（⌘G／⇧⌘G）、使用选区查找（⌘E）。文件菜单保留新建、打开、保存、另存为和关闭的标准快捷键。
- 替换使用与查找相同的字面匹配和忽略大小写选项，不支持正则或反向引用。提供当前匹配替换和全部替换；范围明确选择左侧、右侧或两侧，每次打开替换时默认当前编辑侧。保留左右独立撤销，替换只更新会话，用户手动保存后才写原文件。
- 每侧 10,000 个匹配仅是显示与导航限制。全部替换处理所选范围的全部匹配，并支持取消与版本校验；任一目标的结果超过 64 × 1024 × 1024 个 UTF-16 码元时取消本次替换，不发布部分修改。删除预览文字始终不属于右侧源文。
- “CrossDiff → 设置/Setting…”（⌘,）打开独立窗口，通过固定双语标签“语言/Language”选择 English 或简体中文，也可切换浅深色外观。语言切换立即更新应用菜单、界面与应用自有提示，无需重启，也不改变系统语言。
- 首次语言按系统首选语言选择，中文使用简体中文，其余使用英文；已保存的选择优先。语言与外观写入本机 `preferences.json`，与 `sessions.json` 分开，清除会话不重置偏好。读取或保存失败必须明确提示。
- 本地化范围覆盖 CrossDiff 自有文案。文件对话框内部控件及系统、第三方服务条目的语言由 macOS 或服务方提供；应用设置的标题、说明和操作按钮随应用语言切换。
- 原生验收覆盖中英文菜单和快捷键、窗口焦点、替换撤销、设置恢复，以及中英文设置窗口的实际渲染。验收未完成的项目在交付记录中单独说明，不以编译成功代替行为验证。

## 0.3.1 控件与导航外观

- 设置窗口内切换浅深色时，语言选择器的文字、底色和菜单保持清晰可读。
- 主工具栏的打开按钮使用轻边框；右上角提供无文字的撤销／重做图标，响应当前输入焦点、保留独立撤销，无法执行时禁用。
- 查找和差异跳转使用短暂的淡蓝描边定位，覆盖编辑器与删除预览；提示不放大文字、不改变原文或抢焦点，并尊重系统减少动态效果设置。

## 0.4.1 图片手动对齐

- 左右图片独立控制大小（10–400%）与旋转（−180° 至 180°，正值顺时针），同时支持滑块和数值输入。拖动图片调整位置，各侧可单独重置大小、角度与位置；不修改原文件。
- 并排、叠加、滑动对比与像素差异共用变换后的画布。组合视图可选择拖动左图或右图；整体视图缩放只影响观察，独立于单图大小。
- 像素差异提供默认关闭的“仅比较重叠区域”，用于核对原图和裁剪图的共同部分；区域覆盖与透明度独立，透明像素仍参与比较，无重叠时明确提示。
- 图片对齐和查看状态保留到当前标签关闭或应用退出，不持久化到重启后的会话。后台渲染可取消，过期结果不得覆盖新参数。
- 解码与变换后的预览画布最长边均不超过 1600 像素；动画图片只比较首帧。缩放、旋转与压缩可能留下像素差异，不承诺自动配准或无损全分辨率验证。

## 0.4.2 图片四角缩放与翻转

- 每侧默认锁定长宽比，拖动四角手柄时固定对角并等比缩放。并排显示两侧的手柄，组合视图只显示当前操作图片的手柄。
- 每侧提供比例锁按钮；解锁后可非等比伸缩，大小控件切换为独立的宽度、高度滑块和数值输入，各轴支持原图的 10–400%。再次锁定保留当前比例，大小控件显示两轴百分比的较大值，后续缩放共同调整两轴；任一轴到达范围边界时共同停止，不改变比例或突然还原形状。
- 每侧独立提供水平、垂直翻转按钮；翻转与四角缩放沿图片旋转后的本地轴执行，拖动越过固定对角时停在最小尺寸，不自动翻转。
- 单侧重置恢复 100% 大小、零旋转、零位移、关闭两种翻转及锁定长宽比。变换不改变源文件，不支持透视或自由扭曲，不跨应用重启保存。

## 0.13.2 裁剪范围与连续内容

- 将几何对应范围与相似内容分层显示：OpenCV 求两图源边界在已接受配准下的凸多边形交集，虚线描边；内容核验结果独立填色，不用范围轮廓填满修改或透明孔洞。
- 相同的平坦区域在可靠配准后可通过严格绝对颜色检查，接入含足够纹理证据的连续组；纯色区域不能独立建立匹配。网格在有效范围边缘裁剪，减少纯裁剪中的无意义留白。
- 保留默认关闭、缓存与取消、左右联动，以及所有手动变换。回归包括纯裁剪、左右对调、缩放旋转、背景改色、局部遮挡与窄窗口显示。

## 0.13.1 相似区域

- 智能对齐成功后提供默认关闭的“相似区域”持久开关，低透明度填充与细轮廓标注，编号与前后导航联动选择两侧对应部分。
- 依已接受的配准对原始解码预览做局部纹理及颜色残差核验，通过 OpenCV 四连通分组，保留孔洞，不将包围框、凸包或画布重叠范围当作相似证据。只显示最多 12 个较大区域，低纹理与未标注部分保持不确定。
- 后台按需分析，可取消且检查请求版本；关闭保留已完成缓存，重新对齐、换图、重读和恢复时失效。手动变换仅影响标注位置，不重写原始证据或源文件，不修改现有像素差异结果。
- 详细方法与边界见[相似区域设计](architecture/image-similarity-regions.md)。

## 0.13.0 图片智能对齐

- 基础图片比较提供显式“智能对齐”，使用 OpenCV SIFT、双向描述子匹配和 RANSAC 相似变换；以左侧原始解码坐标为参照，替换两侧预览变换，并保留一份操作前快照。失败与取消保留当前手动参数。
- 成功时并排视图切换到滑动对比；其他模式保持。可选显示少量编号验证点，并支持继续手动微调、“恢复对齐前”。切换标签保留匹配证据，重新读取清除证据和快照；不写原文件、不跨应用重启持久化。
- 分析以最长边不超过 1600 的已定向 sRGB 预览为依据；坐标转换必须与实际渲染一致。仅处理单一整体旋转、等比缩放和位移，适用于有足够共享细节的裁剪／修改版本；不承诺自动透视、翻转、非等比变换或多个独立局部对应。
- 证据包括对应点、内点数量、中位重投影残差和覆盖；不把残差称为正确率，也不把未匹配解释为删除／遮挡。对于细节不足、歧义和超出控件范围的变换不静默截断或强制应用。
- OpenCV 运算置于后台，取消在算法阶段之间检查；重试串行，手动变换或换图使旧任务失效。无需学习型权重，后续可选模型资源独立设计。


## 0.5.0 框架第一步

保留原界面，新增实验插件协议、独立 JavaScriptCore helper、原生页面／表格视图与插件管理窗口。已实现 PDF 只读比较和独立 JSON 插件示例；协议的三方／多对象角色可校验，但当前界面和附带算法仍为两方比较。详细实际契约见 [插件开发规范](plugins/development.md)，联网与信任边界见 [SECURITY.md](../SECURITY.md)。

## 0.6.0 内置二进制比较

基础功能增加两方、只读的 Hex 比较：本地普通文件、真实源偏移、十六进制与 ASCII、插删对齐、差异导航、地址跳转及选中复制。按需读取和绘制，每侧上限 8 GiB，复杂区域可降级为明确标注的粗略对齐。会话仅保存路径；尚不支持二进制修改、补丁导出、远程二进制或三方 Hex。

## 0.7.0 压缩包基础插件

压缩包比较属于基础能力，以官方内置受限插件交付。压缩包作为虚拟目录，可与另一压缩包或本地目录互比，流式读取内容，不向磁盘解压。首版支持 ZIP、TAR 和 gzip/bzip2/xz 包裹的 TAR；原生树显示路径与目录差异，独立同内容分组查找不同路径下的相同文件。只读、不跟随链接、不递归展开嵌套压缩包；异常、超限与未验证内容必须明确呈现。

宿主负责受限读取、内容摘要与结果验证，插件负责路径匹配、分类、目录汇总和内容分组。已有文本、文件夹、图片与 Hex 不在本次强制迁移。具体格式限制和用法见[压缩包指南](usage.md#archives)，接口见[插件规范](plugins/development.md)。

## 0.7.1 新建比较流程

- 主工具栏“新建…”与文件菜单新建（⌘N）先展示比较类型；选择后进入左右输入页。保留轻边框、原生控件与浅深色主题。
- 类型包含文本、文件夹、图片、二进制及已启用插件提供的比较；“更多对比项”打开插件管理。“比较”菜单直接进入指定类型的输入页。
- 文本左右两侧可分别使用临时文字或文件；选择来源和返回类型页不覆盖当前比较。仅开始比较后创建新标签，取消不留下空白标签。
- “文件 → 打开…”（⌘O）、Finder 打开与窗口拖入继续自动识别来源；多个输入明确配对后各自打开比较标签。

## 0.8.0 发行组合与官方插件安装

- 基础版包含文本、文件夹、图片、Hex 与官方压缩包插件；完整版在相同宿主上内嵌全部当前已发布的官方插件，包括 PDF。专业插件的未来规划不计入当前完整版。
- 每个 Release 同时提供两种应用包、独立官方插件包、明确标注的 JSON 示例包、对应源码、构建信息、插件目录与校验和。
- 官方目录随应用内嵌，可离线查看。只有用户点击“下载并安装”时才访问目录固定的 GitHub Release 地址；校验完整包字节、大小、标识、版本、兼容性及受限 JavaScript 运行方式后安装并启用。
- 官方安装不能批准原生完全信任模式。外部文件、拖入和任意 HTTPS 链接仍保留安装预览；没有后台联网、插件轮询或静默升级。
- 两个版本使用相同本地数据目录；内置版本优先于相同标识的外部安装，原有外部登记保留，切回基础版后仍可用。

## 0.9–0.11 专业比较插件

- **摄影：** 只读分析照片与参考作品，默认双图、直方图与差异摘要。专业图表在当前源码 0.15.0 中改为默认展开，仍可手动收起。左右独立框选，可联动并保存多组命名区域。使用 Apple 颜色管理、RAW 解码与 OpenCV 统计；处理曲线仅在文件或 XMP 有明确记录时展示，不从成片推测作者参数。
- **API：** 对已记录的 HTTP、cURL 与 HAR 做本地只读比较，不执行请求。分别呈现请求／响应、头、参数与 JSON 字段，区分字段缺失、null 和类型变化；波动字段只在用户明确设置后忽略。日志仍可使用文本比较，网络抓包不属于此插件。
- **音频：** 双时间线、波形、STFT 与平均频谱；可配置分析参数，左右独立选区及命名区域对，支持只读 A/B 试听、B 侧独立速度／音高预览。自动匹配先实现同源、固定速度录音的截取、重排与重复候选；候选需试听确认，不把未匹配直接解释为删除。自动变速／变调识别仍属后续研究。
- 三个插件均随 0.11.0 源码的 Full 版本交付，Base 可安装与宿主兼容的独立包。可公开下载的具体版本以 GitHub Releases 为准。领域契约与实际限制见[使用指南](usage.md)、[插件规范](plugins/development.md)和[验收记录](validation/README.md)。

# Using CrossDiff

CrossDiff compares text, folders, images, binary files, archives and PDF documents on your Mac. Full also includes Photography, API Compare, Audio and Office plugins. This guide describes the 0.12.2 source preview; see GitHub Releases for published builds. There is no sign-in. For build instructions, see the [development guide](development.md); for planned capabilities such as legacy Office and full visual comparison, see the [roadmap](roadmap.md).

## Start a comparison

Click **New… / 新建…** (`⌘N`) in the toolbar or File menu. Choose a comparison type, then prepare the left and right inputs on the next page and start the comparison. Text accepts temporary pasted content or a file on each side. Folder, image and binary comparisons accept the corresponding sources; archive, PDF, photography, API and audio comparisons appear when the corresponding installed plugins are enabled. **More Comparisons / 更多对比项** opens plugin management. The **Compare** menu goes directly to the input page for a chosen type.

**File → Open…** (`⌘O`) still selects multiple files or folders and detects their types. Two compatible items open as a comparison. When you select more items, assign explicit left/right pairs before opening each comparison in its own tab. Finder opening and dropping items into the comparison window retain this automatic routing. You can also paste directly into an existing text comparison.

To try a synthetic example, open [CompareOptions-before.swift](../examples/CompareOptions-before.swift) and [CompareOptions-after.swift](../examples/CompareOptions-after.swift) together. They demonstrate character edits, inserted lines, and deleted lines.

## Read and edit text changes

Both sides are editable. Red indicates removed content and green indicates added content. Switch between character and whole-line detail in the comparison bar.

Corresponding visual rows align by default, including wrapped lines. A subtle gap row with “—” fills space where the other side has extra content. These gaps are visual only; they do not change source text, copied text, or saved files. **Options** lets you adjust alignment, word wrapping, synchronized scrolling, and ignored differences. Ignoring whitespace or case changes comparison results, not the underlying text.

Click a change in the text or gutter to select it. The footer shows the active change and provides buttons to merge that block in either direction. Use `⌥⌘↓` / `⌥⌘↑` to navigate changes. A brief blue outline marks the destination without enlarging the text.

Each side has its own undo history, preserved across comparison tabs. The toolbar undo/redo icons and `⌘Z` / `⇧⌘Z` act on the current text input, including a focused search field.

**Editing and merging do not overwrite original files automatically.** The save icon saves its own side; `⌘S` saves the current editing side and `⇧⌘S` uses Save As. CrossDiff checks for external file changes before saving.

## Review deleted content on the right

**Show Deletions** is off by default. Turn it on to read a right-side preview with deleted text shown in red with a strikethrough. Additions remain green. This preview is selectable and read-only; turn it off to resume editing.

- Ordinary copy (`⌘C`) includes only selected right-side source text, excluding inserted deleted content.
- Right-click and choose the explicit revision-copy action to include deletions and additions. The clipboard contains rich text with strikethrough and plain text with `[-removed-]` / `{+added+}` markers.
- The right-side footer's Copy menu offers the entire source or the entire text with revisions.

Preview text never enters the source, undo history, saved file, or restored session. Show Deletions returns to off on the next app launch.

## Find and replace

`⌘F` opens search across both source texts. Search supports literal text and optional case-insensitive matching. `⌘G` / `⇧⌘G` move through matches, even after `Esc` dismisses the search bar. `⌘E` uses the current selection as the query. Deleted text inserted only for the preview is not searched as right-side source.

`⌥⌘F` opens find and replace. Choose the left side, right side, or both. Each time you open replacement, the scope defaults to the current editing side. You can replace the current match or every match in the chosen scope. Replacements are undoable and do not write to original files until you save.

Matching is literal: regular expressions and replacement backreferences are not supported. Navigation displays at most 10,000 matches per side and shows a limit notice if needed; **Replace All still processes every match** in its chosen scope. See [implementation limits](development.md#current-implementation-limits) for file and replacement size limits.

## Clear text or session history

**Clear Both** empties the current comparison's two panes and returns them to editable mode. The same control becomes **Undo Clear**, restoring both texts until you type again or open another file. Native undo histories are also retained. This does not close other tabs, erase other session history, or automatically change original files.

CrossDiff restores comparisons locally on the next launch. **Session → Clear Local Session History…** asks for confirmation, then closes all comparisons and removes saved temporary text. It leaves original files, language, and appearance preferences unchanged. Compared text and paths may be present in the local session file. See the [privacy details](../SECURITY.md#local-data-and-file-handling).

## Compare folders / 文件夹比较

文件夹比较先递归检查路径、类型和大小，直接显示仅单侧存在、类型不同及大小不同的项目；同大小的普通文件随后使用 SHA-256 核验内容，默认最多两个文件比较任务并行。大小与时间戳相同不能证明内容相同。扫描期间可查看部分结果，上方显示发现数量、内容核验进度及实际读取量；尚未核验的项目标为“待校验”。取消后保留部分结果，但不能据此复制。

Folder comparisons first inventory paths, types and sizes, showing one-sided entries, type mismatches and size differences immediately after enumeration. Equal-size regular files are then verified with SHA-256, with up to two comparison tasks at a time by default. Matching size and timestamps never establish identical contents. Partial results remain visible while the progress bar reports discovered items, verified pairs and bytes read. Unverified entries are marked **Pending**; canceled partial results cannot be used to copy files.

默认忽略 `.git`、`.build`、`node_modules` 和 `.DS_Store`。点击 **忽略规则 / Ignore Rules**，每行输入一个完整文件名或目录名；在任意层级精确匹配，忽略目录时也跳过其内容。不支持通配符或路径，规则仅用于当前比较；点击“应用并比较”重新扫描。

**Ignore Rules** accepts one exact file or folder name per line at any depth, without wildcards or paths. Ignoring a folder skips its descendants. Rules apply only to the current comparison; choose **Apply & Compare** to rescan. The four names above are the defaults.

同一次运行中，切换标签会保留结果、扫描任务、筛选、选择及忽略规则，不重新读取目录。结果是上次扫描的快照，右下角显示完成时间；外部文件变化后点击 **重新比较 / Compare Again** 更新。重启应用会重新扫描，不把旧内容摘要作为文件相同的依据。

Switching tabs during the same app run preserves results, active scans, filters, selection and ignore rules. Results are a snapshot with a completion time, not a live filesystem view. Use **Compare Again** after external changes. Restarting the app scans again; old content hashes are not reused to declare files identical.

Select a regular file in a completed comparison to copy it in either direction. CrossDiff first lists planned additions and overwrites, then checks the inputs again before executing. Contents not needed during the scan are verified when preparing the copy. It does not perform full synchronization or batch deletion and does not follow or copy symbolic links. If a copy sequence fails partway through, completed copies remain; compare the folders again before continuing.

<a id="archives"></a>
## Compare archives / 压缩包比较

Choose **Compare → Archive Comparison… / 比较 → 压缩包比较…**, then select two archives, or an archive and a local folder in either order. The normal **Open…** and drag-in pairing paths also recognize compatible archive/folder pairs. For more than two inputs, explicitly assign the pairs. The official archive plugin is included and enabled by default; it can be disabled in **CrossDiff → Plugins…**. An explicitly selected archive comparison also accepts two local folders under these read-only content-comparison rules.

Supported formats: ZIP (stored/deflate), TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2 and TAR.XZ/TXZ. Extension alone does not prove a valid format. Gzip, bzip2 and xz streams must contain TAR. RAR, 7z, encrypted archives, multi-volume archives and recursive expansion of nested archives are not supported. ZIP64, non-UTF-8 names and ZIP Unicode-path override extra fields are currently outside the supported ZIP subset. XZ accepts a single stream without trailing stream padding, with one LZMA2 filter per block and at most a 64 MiB dictionary. CRC32, CRC64 or SHA-256 checks are required; the index is capped at 1 MiB, with at most 10,000 blocks and 100,000 chunks.

**By Path / 按路径** presents an expandable native directory tree. A file is **Same** only when its length and SHA-256 digest match; timestamps and permissions are not compared. Directories summarize their descendants, preserving empty directories. Use the path filter and **Changes Only / 仅差异** to focus the tree; ancestors remain available. **Same Content / 相同内容** groups verified matching files at different paths across the two sources, keeping every member without generating a Cartesian list. This is evidence of identical contents, not an inferred rename or move.

The operation is read-only: compressed contents are decoded as bounded streams in memory, **without extracting files to disk**. Nested archives are ordinary files. Symbolic links, hard links and special entries are never followed and remain **Unverified**; their targets are not considered equal. Corruption, encryption, unsafe paths, conflicting or duplicate entry paths, and reading limits stop the comparison rather than produce a misleading match. Source changes detected before publication or cached reuse invalidate the result; choose Reload to scan again. This is change detection, not an immutable filesystem snapshot.

Each side allows up to **10,000 entries** including implicit directories, **512 MiB** of expanded data, **256 MiB** per file, and **2 GiB** per compressed archive. Paths are limited to **4096 UTF-8 bytes** and **128 components**. TAR has an additional **544 MiB** decoded-stream cap, allowing at most 32 MiB above the content budget for headers and padding. Local folder comparison through this plugin includes hidden files and uses the same content budgets; it does not inherit the normal folder comparison's ignore list. Path matching is case-sensitive and treats canonically equivalent Unicode names as the same path; ambiguous names in one archive are rejected.

There is no extraction, contained-file editing, merge, copy-back or export action in this release. Saved sessions retain source paths and plugin identity, not expanded file bytes. For byte-level differences in the archive file itself, use **Binary Comparison…** instead.

## Compare images

**0.13.0 源码预览：** 点击 **智能对齐**，以左侧原图为参照，自动调整右图的大小、旋转和位置。成功时，并排视图会切换到滑动对比；其他模式保留。可开启 **对应点** 查看少量带编号的验证点，继续手动微调，或点击 **恢复对齐前** 恢复此前两侧的变换、比例锁和比较模式。重新读取图片会清除旧的匹配证据与恢复记录，保留当前变换。

匹配完全在本机使用 OpenCV SIFT 和稳健几何估计完成，无需下载模型。适用于具有足够细节的同源图片，包括旋转、等比缩放、裁剪及部分局部修改；细节不足、重复图案歧义或变换超限时保留当前对齐并说明原因。误差数字是验证点的中位配准误差，不是修改比例或置信度。对应点不能代表完整区域边界，未匹配区域也不等于被删除或遮挡。首版不自动处理透视、翻转、非等比拉伸或多个独立移动／拼接区域；可继续使用手动操作。

**0.13.0 source preview:** Choose **Smart Align** to align the right image to the original left image using scale, rotation and position. A successful estimate switches Side by Side to Wipe; other modes remain unchanged. **Match Points** shows a small numbered sample of verified correspondences. Continue refining manually or use **Restore Alignment** to recover the previous transforms, aspect locks and comparison mode. Reload clears old match evidence and the restore snapshot while retaining the current transforms.

Matching runs locally with OpenCV SIFT and robust geometry, without model downloads. It handles sufficiently detailed versions of the same image, including rotation, proportional resizing, crops and some local edits. Insufficient or ambiguous evidence and unsupported transforms leave your alignment unchanged. The reported error is the median registration residual, not the edited fraction or a confidence score. Points are not complete region boundaries, and unmatched areas do not establish deletion or occlusion. Automatic perspective, reflection, nonuniform scaling and independently moved/composited regions are outside this first version; manual controls remain available.

Choose **Side by Side**, **Overlay**, **Wipe**, or **Pixel Difference**. Every mode uses the same aligned canvas and applies the same adjustments. **View Zoom** magnifies the whole comparison; it does not change either image’s relative size.

Each image has its own size, rotation, and flip controls:

- Drag a corner handle to resize the image while keeping the opposite corner in place. **Aspect ratio is locked by default.** Side by Side shows handles for both images; Overlay, Wipe, and Pixel Difference show handles for the image selected beside **Drag to Align**.
- Click that image’s aspect-ratio lock to stretch it freely. The Scale control becomes separate **Width** and **Height** sliders and numeric fields. Locking it again preserves its current proportions; it does not undo the stretch. Subsequent resizing changes both dimensions together.
- Unlocked **Width** and **Height** each range from **10% to 400%** of the source image. When locked, **Scale** shows the larger of those two percentages and changes both dimensions proportionally. Resizing stops when either dimension reaches its limit, preserving the shape. Drag a slider or type a value, then press Return or leave the field to apply it.
- Rotation ranges from **−180° to 180°**; positive angles rotate clockwise. Typed angles outside that range wrap to the equivalent angle.
- Use the horizontal or vertical flip button for either image. Flips mirror the image along its own axes, so they follow its rotation. Corner resizing also follows the rotated and flipped image’s axes; dragging past the opposite corner stops at the minimum size without flipping it automatically.
- Drag the image body to move it. In Side by Side, each pane moves its own image. In Overlay, Wipe, or Pixel Difference, select **Left Image** or **Right Image** beside **Drag to Align** first. In Wipe, drag the central divider handle to move the divider instead of the image.
- Use the reset icon beside either filename to restore 100% size, zero rotation and offset, no flips, and a locked aspect ratio. The reload icon reads the source files again while keeping the current adjustments.

For an original image and a cropped version, start with **Overlay**. Adjust the cropped image’s Scale and Rotation if necessary, then drag it until recognizable features overlap. Switch to **Pixel Difference** and turn on **Compare Overlap Only** to exclude areas not covered by both images. This option is off by default; transparent pixels within the shared image area still participate. If the images do not overlap, CrossDiff displays a notice instead of presenting an empty overlap as a match. Without this option, differences include areas covered by only one image; blank canvas outside both images is excluded.

All adjustments affect previews only; CrossDiff does not apply perspective or free-form warping, or write the transformed result to either source file. Alignment, match evidence and viewing state survive switching comparison tabs in the current app session, but image alignment is not restored after restarting the app.

Comparison uses an 8-bit sRGB preview with a maximum 1600-pixel longest edge. Images are decoded at a shared scale, and an enlarged or rotated canvas is reduced again if needed. Zoom and difference counts refer to these previews, not to a full-resolution lossless analysis. Scaling, rotation, resampling, and source compression can leave small differences even after visual alignment. Only the first frame of animated images is compared.

<a id="photography"></a>
## Photography / 摄影对比

**摄影插件 Photography 0.1.0。** 当前公开的 0.12.0 与待发布的 0.12.1 Full 均预装；同版本 Base 可安装独立摄影包。安装并启用后，选择 **新建… → 摄影**，分别选择两张照片。普通图片的自动打开仍使用基础图片比较，摄影入口需显式选择。

**Photography 0.1.0.** The public 0.12.0 and upcoming 0.12.1 Full editions both bundle this plugin; a matching Base host can install its standalone package. Enable the plugin, choose **New… → Photography**, and select the two photographs. Ordinary automatic image opening continues to use basic image comparison.

默认以双图为主，显示同刻度的 RGB 与 **HSL 明度 L** 直方图，以及低明度、高明度、高饱和区域占比的简短对比。**专业图表**展开 HSL、处理曲线、拍摄与分析信息。HSL L 不是物理亮度或曝光值，图表描述所选画面的分布，不给作品评分，也不反推调色滑块。快门、光圈、ISO、焦距等仅显示实际文件记录，缺失不猜测。

The default view pairs the photographs with RGB and **HSL lightness L** histograms on shared scales and short comparisons of low-lightness, high-lightness and high-saturation shares. **More Analysis** reveals HSL distributions, recorded curves, and capture/analysis information. HSL L is not physical luminance or exposure. Charts describe selected image content, without quality scores or inferred editing sliders. Shutter speed, aperture, ISO and focal length come only from recorded metadata.

- **框选区域 / Select regions:** 在照片上拖动矩形，松开后重新统计。左右默认独立，可在不同位置选择天空或肤色等可比内容；不修改源照片。Drag a rectangle and release to analyze it. Each side is independent by default, so matching subjects may occupy different positions.
- **联动选区 / Link Regions:** 开启后，之后的框选在两图使用相同的归一化位置与比例；不是物体识别或自动配准。Future selections share normalized coordinates and proportions, without object recognition or registration.
- **保存区域 / Save Region Pair:** 点击加号、命名，最多保存 32 组左右配对；通过“已存区域”切换或删除。区域与所选 XMP 路径随本机会话保存。Use the plus button to name up to 32 pairs, then switch or delete them in Saved Regions. Region pairs and selected XMP paths persist with the local session.
- **全图 / Whole Image:** 清除当前框选并重新统计全图，不删除已存区域。Clears active selections without deleting saved pairs.
- **处理曲线 / Recorded Curves:** 显示图片内嵌或手动选择的 Adobe CRS XMP 控制点；选择旁路 XMP 时以该记录为准。连线只作示意，不复现原软件插值、显影或调色效果。不存在记录时显示“未记录处理曲线”。Shows actual embedded or explicitly selected Adobe CRS XMP control points; a selected sidecar takes precedence. Lines are illustrative, not the original editor’s interpolation or rendering. Missing records remain missing.
- **重新读取 / Reload:** 重新加载照片并分析。查看预览的缩放相对于显示预览像素，不能当作原图 100% 细节。Reloads photographs and statistics. Inspector zoom is relative to preview pixels, not 100% original-image detail.

Apple ImageIO／Core Image 读取普通图片和颜色配置，`CIRAWFilter` 以 Apple 默认设置显影 RAW。常见 RAW 后缀包括 DNG、CR2／CR3、NEF、ARW、RAF、RW2、ORF 等，但支持依赖**具体机型、编码模式和 macOS 版本**；后缀可选不代表可解码。失败时明确报错，不用内嵌预览冒充完整 RAW。默认显影不等于相机原始采样值或原作者调色结果。

Apple ImageIO/Core Image reads ordinary images and color profiles; `CIRAWFilter` renders RAW with Apple defaults. Common RAW extensions include DNG, CR2/CR3, NEF, ARW, RAF, RW2 and ORF, but support depends on the **camera, encoding mode and macOS version**. An accepted extension is not a decoding guarantee. Unsupported RAW fails explicitly without substituting an embedded preview. Default rendering is neither raw sensor samples nor the creator’s final edit.

分析使用统一的 **sRGB 浮点 SDR 0–1** 数据，OpenCV 4.12.0 提供 HSL 转换和直方图。超范围数值截至端点，不能以此判断 RAW 过曝；完全透明和非有限像素排除，其余有效像素等权，HSL 饱和度低于 2% 的像素单独记作中性色并排除出色相分布。直方图按有效像素占比归一化，不因选区大而自动更高。

Analysis uses **floating-point sRGB SDR values in 0–1**, with OpenCV 4.12.0 providing HSL conversion and histograms. Out-of-range values are clamped, not interpreted as RAW overexposure. Fully transparent and non-finite samples are excluded; other valid pixels receive equal weight. HSL saturation below 2% counts as neutral and is excluded from hue bins. Histograms show fractions of valid pixels, so larger selections do not automatically produce taller charts.

每张照片上限 **256 MiB／6400 万像素**。显示预览最长边 **2048**；统计直接来自颜色管理后的源图选区，最长边超过 **4096** 时采用有界采样，并显示采样状态及尺寸。多帧文件只分析首帧。波形、矢量示波图、噪声／锐度评分、HDR 专业分析、图表点选反向高亮、报告导出和照片编辑不在此版范围内。

Each photograph is limited to **256 MiB and 64 megapixels**. Display previews have a **2048 px** longest edge. Statistics use the color-managed source region, with bounded resampling above a **4096 px** longest edge and an explicit sample indicator/dimensions. Only the first frame is analyzed. Waveforms, vectorscopes, noise/sharpness scores, professional HDR analysis, reverse highlighting from chart selections, report export and photo editing are not included.

<a id="api"></a>
## API 对比 / API Compare

**API 0.1.0。** Full 预装，Base 可安装同版本发行目录中的独立包；0.8.0/0.9.0 宿主不支持 HTTP 输入契约。

1. 选择 **新建… → API 对比**，两侧各粘贴一份 HTTP 请求/响应、常见浏览器复制的 cURL 命令，或 HAR 1.2；也可选择 `.http`、`.curl`、`.har` 等本地文件。
2. HAR 包含多次调用时，在左右上方分别选择要比较的记录。请求与响应属于同一次调用，不是互相比较。
3. 按“请求”“响应”筛选，查找字段或值；JSON 用路径和类型展示，数组顺序保留，字段缺失和 `null` 不相同。头名称不区分大小写，同名头与参数保留重复顺序；JSON 数字保留原始精度及写法。
4. 可明确设置忽略头（如 `Date`）和 Body JSON Pointer（如 `/metadata/requestId`），规则作用于左右请求与响应，路径包含子字段。默认无忽略；底栏可查看被忽略字段。
5. 原文查看需显式点击显示；“重新读取”加载最新文件。记录选择、规则和粘贴内容随本机会话恢复。

只在本地解析，**不会运行 cURL、发送请求、展开变量或读取命令引用的 `@file`**。cURL 支持常见导出语法的子集，最多 20,000 个词法单元；多地址展开和无法可靠解析的选项会提示。XML 和其他文本 body 按原文比较；未记录或不能解码的 body 显示未知，不当作空白或相同。HAR 不是网络抓包；不提供 PCAP、抓包、接口测试、OpenAPI 契约差异或日志专用分析。

每侧输入最多 **4 MiB UTF-8／500 次 HAR 调用**，每个 body 最多 **1 MiB**；JSON 最多 64 层／20,000 节点，每次调用最多 5,000 字段。结果最多 5,000 行并有总输出大小限制；截断明确显示部分结果。原文视图最多预览 65,536 字符，单元格最多预览 4,096 字符；比较仍使用上限内的完整导入值。

默认遮罩常见凭据字段的展示值，真实值照常参与比较；这不是完整脱敏。粘贴记录可能含令牌、Cookie 或正文秘密，并按既有机制**明文保存在本机会话**；可通过“会话”菜单清除记录。源文件不被修改。

**API 0.1.0.** Full bundles this plugin; a Base host can install the package from its matching release catalog. Hosts before 0.10.0 do not support the HTTP input contract.

Choose **New… → API Compare** and paste or open two HTTP/cURL/HAR sources. Each side represents an HTTP call, with its request and/or response. Select HAR records independently, filter request/response sections, search fields, and inspect JSON paths and types. Missing differs from null; array order and duplicate headers/parameters are retained. JSON numbers retain their exact spelling and precision. Explicit ignored header names and JSON Pointer subtrees remain inspectable, and selections/rules are restored with the session.

Everything is parsed locally and read-only: cURL is never executed, requests are never sent, variables are never expanded, and referenced files are never opened. Unsupported cURL options and multiple-URL expansion are rejected; parsing is limited to 20,000 tokens. XML and other text bodies use literal text comparison. Missing or unsupported bodies remain unknown. This does not include PCAP, live capture, API testing, OpenAPI contracts, or specialized log analysis.

Limits: 4 MiB UTF-8 and 500 HAR calls per input; 1 MiB per body; JSON depth 64/20,000 nodes; 5,000 fields per call and up to 5,000 result rows, also bounded by total output size. Partial results are marked. Source and cell previews are limited to 65,536 and 4,096 characters respectively without changing the underlying comparison. Common credential fields are masked for display by default, not sanitized in storage. Pasted records are restored from plaintext local sessions; use the Session menu to clear them. See the [implementation scope](architecture/api-comparison.md).

## Language and appearance

**CrossDiff → 设置/Setting…** (`⌘,`) opens a separate settings window. In **语言/Language**, choose **English** or **简体中文**. App-owned menus, controls, and messages update immediately without restarting or resetting edits. These two entry labels always remain bilingual so that you can find the language setting again.

The first launch follows your preferred system language: Simplified Chinese for Chinese, English otherwise. Later launches use your saved choice. Light/dark appearance can be changed in Settings or with the toolbar sun/moon button.

Preferences are local to CrossDiff and do not change macOS or other apps. macOS-owned controls inside file dialogs and system or third-party Services entries follow their own localization.

## Keyboard shortcuts

Menu commands show their shortcuts and enable according to the active window and input field.

| Action | Shortcut | Menu |
| --- | --- | --- |
| Undo / Redo | `⌘Z` / `⇧⌘Z` | Edit |
| Cut / Copy / Paste | `⌘X` / `⌘C` / `⌘V` | Edit |
| Select All | `⌘A` | Edit |
| Find | `⌘F` | Edit → Find |
| Find and Replace | `⌥⌘F` | Edit → Find |
| Next / Previous Match | `⌘G` / `⇧⌘G` | Edit → Find |
| Use Selection for Find | `⌘E` | Edit → Find |
| Next / Previous Difference | `⌥⌘↓` / `⌥⌘↑` | Compare |
| New Comparison / Open | `⌘N` / `⌘O` | File |
| Save Current Side / Save As | `⌘S` / `⇧⌘S` | File |
| Close Comparison or Window | `⌘W` | File |
| Settings | `⌘,` | CrossDiff |

When a search field is focused, editing commands operate on that field. When Settings is in front, they do not modify a comparison behind it.


## PDF 文档与插件 / PDF documents and plugins

在“新建… → PDF 文档”分别选择两侧文件，也可从“文件 → 打开…”选入两个 PDF，或使用“比较 → PDF 比较…”。页面对照保留原版面，左侧列表显示页码对应关系；可切换到文字差异、逐处导航并缩放页面。扫描页和提取受限会明确提示，当前没有 OCR。此视图只读，不改原文件。

0.12.2 源码预览提供三种页面配对方式：

- **按页码（默认）：** 第 1 页对第 1 页，依次比较；多出页面显示为单侧页，不据此断言版本新增或删除。
- **智能匹配：** 适合同一文档的不同版本。使用唯一预览或有信息量的文字寻找顺序一致的对应；证据不足、重复或歧义时明确提示并按页码比较。它不做 OCR 或语义理解，不能保证所有推断配对正确。
- **手动配对：** 两侧分别输入页码或点击前后页，页面预览与文字差异都跟随所选原始页。当前标签保留选页，切换模式后可返回继续；不新增跨重启恢复手动设置的承诺。无效页码提交后恢复当前页。

顶部“第 N / M 组”是比较组位置，两侧文件名下显示各自原始页码。匹配锚点之间缺少明确对应证据的页面仍按相对顺序展示，可用手动配对检查。手动选页限已读取的前 200 页。

Choose each side through New… → PDF Documents, or open two PDFs through File → Open… or Compare → PDF Comparison…. Page view retains page layout and the sidebar shows corresponding pages. Switch to Text Differences for extracted text, navigate changes, or zoom the page. Scanned pages and extraction limits are indicated; OCR is not included. The view is read-only.

The 0.12.2 source preview offers **By Page** (default), **Smart Match** and **Manual Pairing**. Page order compares the same original page numbers without inferring revision history. Smart Match uses unique preview or informative text evidence for related revisions; insufficient or ambiguous evidence falls back to page order with an explanation. It does not perform OCR or semantic analysis, and pages between reliable anchors may still be paired by relative order.

Manual Pairing provides independent page-number fields and previous/next controls on each side. Page previews and text differences follow the selected source pages. Choices remain in the current tab when switching tabs or pairing modes; manual settings are not newly persisted across app restarts. Invalid entries revert to the current page. **Pair N / M** identifies the comparison group; source page numbers appear under the file names. Selection is limited to the pages read (at most 200 per side).

在“CrossDiff → 插件…”管理扩展：选择／拖入 `.crossdiffplugin` 文件，或输入 HTTPS 链接点击“下载并检查”。检查名称、标识、版本、未验证发布者与运行权限后安装。任意链接下载需先检查再安装。重复安装同一个版本但内容不同会被拒绝；更新请使用新的版本号。

Manage extensions under CrossDiff → Plugins…: choose or drop a `.crossdiffplugin` file, or enter an HTTPS URL and click Download & Inspect. Review the name, identifier, version, unverified publisher and runtime permissions before installation. Downloads from arbitrary URLs require review before installation. Changed packages must use a new version number.

官方插件列表随应用提供，离线可查看。点击“下载并安装”后，应用从固定版本的 GitHub Release 下载，核对整包 SHA-256、大小、标识和版本，再自动安装受限插件。基础版内置压缩包插件；当前完整版额外预装 PDF、摄影、API、音频与办公。基础版可安装兼容的独立包；未发布版本的目录下载地址需等待对应 Release 发布，研发时使用本地打包安装。联网只发生在你主动下载时，比较内容仍在本机处理。

The official catalog is bundled and available offline. Download & Install fetches a version-pinned GitHub Release asset, verifies its complete SHA-256, size, identifier and version, then installs the restricted plugin. Base bundles Archive. The current Full edition adds PDF, Photography, API Compare, Audio and Office. Base can install compatible standalone packages. Catalog URLs for an unpublished version become available only after its Release is published; use local packages during development. Network access occurs only when you request a download; comparison content stays on your Mac.

插件页默认打开**已安装**，卡片上直接提供启用开关与**卸载…**或**移除…**，可先确认再执行；**发现插件**页用于查找和安装。

- 本地安装插件的**卸载**会删除登记及已安装版本；清理失败时会提示，残留文件不会重新启用。
- 预装插件的**移除**只从已安装列表与比较入口移除，应用包中的文件保留，不减少应用体积或破坏签名。移除状态跨重启、升级及 Base／Full 切换保持；在“已移除的预装插件”或“发现插件”卡片上点击**恢复**可离线启用。若切回不含该预装插件的 Base，可显式重新安装。
- 停用、卸载或移除后，原文件和比较会话保留，并提示需要对应插件。外部插件更新后可回退至上一版本。预装插件的更新随应用分发，不能由外部同名标识覆盖。

The plugin manager opens on **Installed**. Cards show an enable switch and **Uninstall…** for local installations or **Remove…** for bundled plugins, with confirmation before proceeding. Use **Discover** to find and install plugins.

Uninstall deletes the local registration and installed versions; failed cleanup is reported and never reactivates leftovers. Remove hides a bundled plugin from Installed and comparison choices while keeping its files in the signed app; it does not reduce app size. Removal persists across restarts, updates and Base/Full switches. **Restore** in Removed Bundled Plugins or Discover enables it offline. In a Base edition without that bundle, explicitly reinstall it instead. Your files and sessions are retained. External updates can roll back; bundled updates ship with the app and cannot be replaced by an external package using the same identifier.

受限 JavaScript 没有文件、网络或进程接口；原生“完全信任”插件有较广权限，需逐版本批准。当前不运行带系统隔离标记的原生插件，不提供绕过系统保护的操作。运行边界见 [SECURITY.md](../SECURITY.md)。

Restricted JavaScript has no file, network or process APIs. Full-trust native plugins have broad permissions and require version-specific approval. Quarantined native executables are not run; the app provides no security bypass. See [SECURITY.md](../SECURITY.md).

体验仓库内的独立 JSON 示例 / Try the independent JSON example:

```sh
source scripts/project-env.sh
python3 scripts/package-plugin.py Plugins/Examples/JSON --output dist/Plugins/JSON.crossdiffplugin
```

将生成文件拖入应用后，从“比较 → JSON 键值比较…”选入两个 JSON 文件。普通打开 `.json` 仍使用文本比较；示例后缀 `.cdjson` 自动使用此插件。示例按解析后的顶层键值比较，不考虑空白、键顺序或重复键，也不作为无损 JSON 解析器。

Install the generated package, then use Compare → JSON Key Comparison… for two JSON files. Ordinary `.json` opening remains text comparison; `.cdjson` routes to this example. It compares parsed top-level values, ignoring whitespace, object key order and duplicate keys; it is not a lossless JSON parser.


<a id="binary-hex"></a>
## 二进制 / Hex

通过 **比较 → 二进制比较…** 选入两个普通文件，可强制按字节比较，包括文本、图片和 PDF。普通“打开…”也会识别含二进制内容的文件；二进制与文本配对时采用 Hex。多文件仍先明确配对。

每侧从左到右显示真实源地址、十六进制、ASCII；不可打印字节显示 `·`。红色表示左侧移除，绿色表示右侧增加，空位 `—` 表示另一侧没有这个字节，不代表 `00`。两侧地址可能不同，这是插入／删除对齐后的正常结果。

- 用底部箭头或 `⌥⌘↓` / `⌥⌘↑` 跳转差异。
- 地址栏选择左／右侧，输入 `0x` 开头的十六进制地址，或十进制地址。地址从 `0` 开始。
- 选择 8／16 字节列宽；窄窗口使用紧凑布局。
- 点击或拖动选中字节，`⌘C` 或右键复制十六进制。复制仅含真实字节；选区限于当前加载页，换页后失效的选区会清除。
- 文件在外部变化时，重新比较以获得新结果。会话只记录路径，下次打开重新读取。

每侧文件上限 **8 GiB**；有界算法不保证全局最短编辑路径，复杂区域会显示粗略对齐提示。对齐精度影响差异分块，所有字节仍在视图覆盖范围内；不会把未确认的区域标为相同。只读模式不支持二进制编辑、合并或补丁导出。

Use **Compare → Binary Comparison…** to compare any two regular files as bytes, including text, images and PDFs. Ordinary Open also detects binary content; pairing binary with text uses Hex. Multi-file opening keeps explicit pairing.

Each side shows its real source address, hexadecimal bytes and ASCII. Non-printable bytes appear as `·`. Red marks removals, green additions; `—` is an alignment gap, not a zero byte. Addresses can differ after insertion/deletion alignment. Navigate with the footer arrows or `⌥⌘↓` / `⌥⌘↑`. Jump to a left or right source address using decimal or `0x` hexadecimal notation. Choose 8 or 16 columns; narrow windows use a compact layout. Click/drag bytes and use `⌘C` or the context menu to copy hex. Selection is limited to the loaded page and is cleared when it leaves that page.

Each input is limited to **8 GiB**. The bounded algorithm may use explicitly indicated approximate alignment for complex regions; it does not claim a globally shortest edit path. All source bytes remain covered, and unconfirmed regions are never marked equal. Refresh after external file changes. Sessions store paths, not bytes. Binary editing, merging and patch export are not included.
<a id="audio"></a>

## 音频对比 / Audio Compare

在“新建… → 音频”选择两个本地音频。Full 已内嵌 Audio 0.1.0；同版本 Base 可拖入独立 `.crossdiffplugin` 安装。无需另装 Python、Java 或 FFmpeg。

- **看波形与时频图：** 默认上下 A/B 时间线，各声道保持原始幅度，深色包络表示 RMS。拖动选择片段，起止秒数也可输入；放大选区只改变视图。切换“时频图”查看真正的 Hann 窗 STFT。参数面板提供 FFT 长度、步长、线性/对数频率轴、共用 dB 范围和平均频谱。
- **手动对比：** 试听支持单声道和立体声。A 保持原始声音，B 可以独立调整试听速度（0.25–4×，保持音高）和音高（±24 半音）。设置后点击试听；“匹配时长”按双方选区时长设置 B 速度。A/B 切换以当前区域相对位置定位，并非已证明自动同步。支持暂停、停止与循环选区；不会自动播放。
- **保存区域：** 最多 32 组命名区域，同时保存双方选区和 B 试听参数，随本机会话恢复。联动选区采用相同源时间，超出另一侧时保留其原选择；不代表自动识别。工具栏小箭头撤销/重做区域及参数修改。
- **自动查找：** 点击“查找对应片段”，使用随宿主构建的固定版本 Olaf 本地指纹引擎。候选保留剪辑重排与一段被重复引用的关系；点击一条可定位双方选区。边界表示指纹证据范围，尚非逐采样剪辑点。当前自动能力针对固定速度的同源录音，不承诺识别独立变速、变调、连续速度曲线或叠加混音；这些情况下可以手动配对和试听。
- **理解结果：** 没找到对应不等于确定删除。静音、短片段和重复节奏可能无法判断；覆盖时长按每侧区间并集计算。原始文件、选区设置、试听变换与自动证据分别保存/处理，插件不能将未匹配伪装成确定差异。
- **清理临时文件：** 参数面板中的“清理音频临时文件”可移除意外退出后遗留的音频分析缓存，保留仍在运行的任务。正常结束时自动清理；此操作不会删除源音频或已保存的区域。

限制：每侧分析最多 2 GiB、2 小时、8 声道；试听仅支持单声道／立体声，3–8 声道仍可查看波形、频谱与比较结果。导入格式取决于 macOS 解码器，支持选择 WAV/AIFF/FLAC/MP3/M4A/AAC/CAF 等扩展名并不保证所有编码变体。波形为最多 8192 桶/声道的概览包络，放大不会凭空增加采样级细节。谱图使用 48 kHz 分析副本，每次处理选区前最多 30 秒；FFT/hop 配置触及预算会进一步缩短并标记实际范围。双方频率轴相同，超过源 Nyquist 的区域显示无数据；原始高于 24 kHz 的频带不在此图谱内。图谱取逐声道线性功率平均；指纹使用原文件能量最高的一个声道，以避免反相降混抵消。源文件变化需要重新读取。

**English:** Choose **New… → Audio** and select two local files. Full bundles Audio 0.1.0; a matching Base host can install its standalone package. Inspect per-channel waveforms or calibrated STFT spectrograms, select and save up to 32 region pairs, and audition A/B or loop a region. Audition supports mono/stereo. B has independent rate and pitch controls; these never rewrite the source. Find Matches uses a bundled Olaf helper for fixed-speed excerpts of the same recording, including reordered and repeated candidates. Automatic recognition of independent tempo or pitch changes is not supported in this preview. Unmatched regions are not proof of deletion. Analysis accepts up to 2 GiB, two hours and eight channels per side; three-to-eight-channel files remain available for waveforms, spectra and comparison, without audition. Codec support is probed by macOS. Waveforms are bounded overview envelopes. Spectra analyze at most the first 30 seconds of the selected region at 48 kHz, with smaller explicit ranges for dense settings. All comparison remains local.

**Clear Audio Temporary Files** in the parameter panel removes abandoned analysis caches while preserving active jobs. Normal completions clean up automatically. Original audio and saved regions are unaffected.

<a id="office"></a>
## 办公文档 / Office Compare

选择 **新建… → 办公文档**，在两侧选择同类 `.docx`、`.xlsx` 或 `.pptx`。Full 预装 Office 0.1.0；同版本 Base 可安装独立包。旧 `.doc/.xls/.ppt` 请先在办公软件中另存为现代格式。

- **Word：** 按段落与表格行对照，变更文字显示红绿高亮；通过两侧选择器查看已提取的其他文档部分。段落编号不是页码。
- **Excel：** 默认先跨位置匹配完全相同行。点击 **匹配关键列**，选择编号等一列或多列，进一步识别同一记录的修改；左右按相同列位置取键，最多 16 列。重复或空键会标记不确定，不强行配对。无关键列时，剩余记录按位置对照，详情会说明这不证明记录身份。
- **PowerPoint：** 按文稿的实际幻灯片顺序读取文字、表格与可提取备注。两侧可独立选择幻灯片；左侧选择会优先按同名部分、再按位置选择右侧，必要时自行更正配对。
- **阅读差异：** 左右保留原行号；中间符号区分相同、变更、新增、删除和重排。插入导致的行号偏移不等于重排。点击中间符号查看匹配依据、完整单元格、类型、公式与保存的结果。搜索同时检查内容与公式，支持“仅差异”；宽表按列组切换并可横向滚动。
- **原文预览：** 点击文件名旁的眼睛按钮，按需打开系统 Quick Look。展示的是当前磁盘文件，支持情况取决于 macOS；预览不提供与差异逐页同步的承诺。重新读取按钮才会更新比较快照。

**比较范围：** 当前结果与计数针对选中的工作表、文档部分或幻灯片，不是整份文件完全一致的判定。内容比较不等于完整视觉比较；字体、排版、图表、图片、嵌入对象等未完整比较。导入说明与范围入口会列出限制。公式及缓存结果分别保留，不执行公式；缓存可能缺失或陈旧。日期与数值保留原始记录，格式可在详情查看，不模拟 Excel 显示引擎。

解析在本机只读执行，使用系统 ZIP 解码和 Foundation XML；不执行宏、不获取外部关系或 XML 实体，不写出解压文件。每侧文件最多 128 MiB；累计解码 256 MiB，单 XML 16 MiB、保留 XML 64 MiB，单文档内容与请求还受行数、单元格数及协议预算约束。超限或损坏明确报错，不静默截断后宣称相同。

**English:** Choose **New… → Office Documents** and select two files of the same modern format: DOCX, XLSX or PPTX. Full bundles Office 0.1.0; a matching Base host can install the package. Convert legacy DOC/XLS/PPT files first.

Word shows paragraph/table content with character highlights. Excel matches exact rows across positions; **Match by Key** accepts up to 16 columns to identify changed records. Keys use the same column positions on both sides. Duplicate or empty keys remain uncertain; unmatched records without keys use an explicitly labeled positional comparison. PowerPoint follows presentation order and extracts text, tables and available notes. Section selectors work independently; choosing on the left suggests a right-side match by name, then position.

Original row numbers, changes and reorder markers remain separate. Click a center symbol for matching evidence, complete cell values, types, formulas and saved results. Search covers content and formulas. Wide sheets provide column groups and horizontal scrolling. The eye button opens the current file in system Quick Look, whose support depends on macOS; it is not a synchronized page renderer. Reload explicitly refreshes the imported snapshot.

Results cover the selected sections, not complete visual or file identity. Formatting, charts, images and embedded objects are not fully compared. Formulas are never evaluated; saved results may be missing or stale. Numeric/date records preserve source precision, without emulating Excel formatting. Parsing stays local and read-only with bounded ZIP/XML resources, no macro execution, external-relationship fetch or external entities. Unsupported, damaged and oversized inputs report errors. See [implementation boundaries](architecture/office-comparison.md).

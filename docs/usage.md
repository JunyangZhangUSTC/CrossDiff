# Using CrossDiff

CrossDiff compares text, folders, images, Git repositories, binary files, archives and PDF documents on your Mac. Full also includes Photography, API Compare, Audio, Office and Video plugins. This guide covers the 0.15.1 stable release. There is no sign-in. For build instructions, see the [development guide](development.md); for planned capabilities such as legacy Office and full visual comparison, see the [roadmap](roadmap.md).

## Start a comparison

Click **New… / 新建…** (`⌘N`) in the toolbar or File menu. Choose a comparison type, then prepare the left and right inputs on the next page and start the comparison. Text accepts temporary pasted content or a file on each side. Folder, image and binary comparisons accept the corresponding sources; archive, PDF, photography, API, audio, office and video comparisons appear when the corresponding installed plugins are enabled. **More Comparisons / 更多对比项** opens plugin management. The **Compare** menu goes directly to the input page for a chosen type.

**File → Open…** (`⌘O`) still selects multiple files or folders and detects their types. Two compatible items open as a comparison. When you select more items, assign explicit left/right pairs before opening each comparison in its own tab. Finder opening and dropping items into the comparison window retain this automatic routing. You can also paste directly into an existing text comparison.

To try a synthetic example, open [CompareOptions-before.swift](../examples/CompareOptions-before.swift) and [CompareOptions-after.swift](../examples/CompareOptions-after.swift) together. They demonstrate character edits, inserted lines, and deleted lines.

## Browse comparison tabs / 浏览比较标签

从 0.15.0 起，标签超出窗口宽度时，将鼠标移到顶部标签栏即可显示横向滚动条；拖动滑块、使用触控板或普通鼠标滚轮均可左右浏览。新建、切换、关闭标签或调整窗口宽度后，当前标签会自动进入可见区域。手动浏览其他标签时，普通内容刷新不会反复拉回当前页；标签放得下时不显示滚动条。

From version 0.15.0, hover over an overflowing tab bar to show its horizontal scroll bar. Drag the thumb, use a trackpad or scroll an ordinary mouse wheel to browse tabs. Creating, selecting or closing tabs and resizing the window bring the active tab into view. Ordinary content updates preserve deliberate manual scrolling. No scroll bar appears when all tabs fit.

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

<a id="compare-folders"></a>
## Compare folders / 文件夹比较

**浏览目录：** 左右相同路径始终在同一行，两边共享选择与滚动；不存在的一侧显示占位，读取失败时显示未知。默认“目录”模式折叠子目录，通过任意一侧箭头联动展开；双击目录进入该范围，“上一级”和“全部目录”返回上层或根。双击两边都有的普通文件打开比较。

左右标题栏各有 **更换…** 按钮，可在当前标签中替换对应文件夹并立即重新比较，另一侧保持不变。取消或选择同一目录不会重扫；新目录会清空旧选择并返回根范围，保留搜索、筛选、排序、展示模式与忽略规则。扫描期间可以更换；复制核验、确认和执行期间暂时禁用。新路径随本机会话保存。

点击名称、状态、任意一侧的大小表头排序，再次点击反转方向；列菜单可显示左右修改时间。目录模式只重排同级项目且目录优先；“列表”模式在当前范围内跨目录排序。文件大小按真实字节排序，缺失值置后；目录不显示误导性的自身大小。修改时间不同本身不表示内容不同。

状态菜单可查看全部、需关注、内容改动、仅左侧、仅右侧、问题或待校验。搜索当前范围的相对路径，保留并临时展开命中项的祖先；清空搜索恢复原展开状态。目录摘要统计整个子树，折叠不改变数量；悬停可查看详细分类。选择排序后保留，筛选或折叠后隐藏的选择会清除。选择目录不会隐式递归复制。

**Browse folders:** Both panes share rows, selection and scrolling. Missing items have placeholders; unreadable locations remain unknown. **Tree** starts with collapsed folders; either disclosure arrow expands both sides. Double-click a folder to browse within it, then use **Parent Folder** or **All Folders** to return. Double-click a pair of regular files to compare them.

Use **Change…** in either folder header to replace that side and compare again in the same tab. The opposite side stays unchanged. Canceling or selecting the same directory does not rescan. A new folder clears old selections and returns to the root scope while retaining search, filter, sort, view and ignore preferences. Replacement is available during scans, but disabled during copy verification, confirmation and execution. New paths are saved in the local session.

Click either name, status or size header to sort; click again to reverse. The columns menu reveals modification dates. Tree mode sorts siblings with folders first; **List** sorts across the current subtree. Sizes use actual bytes, missing values remain last, and folder sizes display a dash. Different timestamps alone do not imply different contents.

Filter by All, To Review, Modified, Left Only, Right Only, Issues or Pending. Search relative paths within the current scope; matching ancestors expand temporarily, then restore when the query is cleared. Folder summaries count descendants without duplicating ancestors; hover for details. Sorting preserves selection. Filtering or collapsing clears hidden selections, and selecting a folder never recursively copies it.

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

Supported formats: ZIP (stored/deflate), TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2 and TAR.XZ/TXZ. Extension alone does not prove a valid format. Gzip, bzip2 and xz streams must contain TAR. CrossDiff also accepts **unencrypted, single-volume 7z and a limited RAR subset**, described below. Passwords, multiple volumes, self-extracting executables and recursive expansion of nested archives are not supported. ZIP64, non-UTF-8 names and ZIP Unicode-path override extra fields are currently outside the supported ZIP subset. XZ accepts a single stream without trailing stream padding, with one LZMA2 filter per block and at most a 64 MiB dictionary. CRC32, CRC64 or SHA-256 checks are required; the index is capped at 1 MiB, with at most 10,000 blocks and 100,000 chunks.

**7z / RAR compatibility:**

| Format | Accepted subset | Explicit exclusions |
| --- | --- | --- |
| 7z | Copy, LZMA, LZMA2; solid and non-solid; one common BCJ or Delta filter; ordinary compressed headers | AES/passwords, BCJ2, PPMd, Deflate/BZip2/Zstd coders, complex coder graphs, external metadata and unsupported properties |
| RAR4 | Stored files or version-29 compressed data, directories, stored symbolic links marked Unverified | Solid archives, old compressed codec versions, encryption, comments/recovery/service blocks; an explicit end marker is required |
| RAR5 | Algorithm v0, ordinary and solid files, directories, time/owner metadata | RAR 7 algorithm v1/new dictionary encodings, BLAKE2sp, redirections, versioned files, comments/recovery/quick-open/service blocks |

7z and RAR5 dictionaries are capped at **64 MiB**. Both the compressed and decoded 7z header are capped at **1 MiB**. Final acceptance also depends on the system libraries included with macOS; an extension alone is not a compatibility guarantee. Unsupported methods/features, passwords and missing volumes do not yield partial matches. Updating the Archive script alone does not add host decoders: use an application build containing this feature.

**中文提示：** 支持无密码、单卷 7z 和受限 RAR，可使用“按路径”和“相同内容”视图。7z 支持常见 LZMA／LZMA2 固实包；RAR4 不支持固实，RAR5 仅接受算法 v0。密码、分卷、恢复记录、注释等不受支持的特性会明确拒绝；并非所有 `.rar` 文件均可读取。

**By Path / 按路径** presents an expandable native directory tree. A file is **Same** only when its length and SHA-256 digest match; timestamps and permissions are not compared. Directories summarize their descendants, preserving empty directories. Use the path filter and **Changes Only / 仅差异** to focus the tree; ancestors remain available. **Same Content / 相同内容** groups verified matching files at different paths across the two sources, keeping every member without generating a Cartesian list. This is evidence of identical contents, not an inferred rename or move.

The operation is read-only: compressed contents are decoded as bounded streams in memory, **without extracting files to disk**. Nested archives are ordinary files. Symbolic links, hard links and special entries are never followed and remain **Unverified**; their targets are not considered equal. Corruption, encryption, unsafe paths, conflicting or duplicate entry paths, and reading limits stop the comparison rather than produce a misleading match. Source changes detected before publication or cached reuse invalidate the result; choose Reload to scan again. This is change detection, not an immutable filesystem snapshot.

Each side allows up to **10,000 entries** including implicit directories, **512 MiB** of expanded data, **256 MiB** per file, and **2 GiB** per compressed archive. Paths are limited to **4096 UTF-8 bytes** and **128 components**. TAR has an additional **544 MiB** decoded-stream cap, allowing at most 32 MiB above the content budget for headers and padding. Local folder comparison through this plugin includes hidden files and uses the same content budgets; it does not inherit the normal folder comparison's ignore list. Path matching is case-sensitive and treats canonically equivalent Unicode names as the same path; ambiguous names in one archive are rejected.

7z/RAR decoding runs in a bundled helper with a 60-second wall-clock deadline, a 60-second CPU limit, a 16 MiB metadata-response cap and a sampled 512 MiB resident-memory watchdog. Cancellation kills that reader. These are resource controls, **not a security sandbox or a hard peak-memory guarantee**. The parent validates the complete response and source identity before publishing a snapshot. No executable is downloaded and no archive entry is extracted.

There is no extraction, contained-file editing, merge, copy-back or export action in this release. Saved sessions retain source paths and plugin identity, not expanded file bytes. For byte-level differences in the archive file itself, use **Binary Comparison…** instead.

## Compare images

点击 **智能对齐**，以左侧原图为参照，自动调整右图的大小、旋转和位置。成功时，并排视图会切换到滑动对比；其他模式保留。可开启 **对应点** 查看少量带编号的验证点，继续手动微调，或点击 **恢复对齐前** 恢复此前两侧的变换、比例锁和比较模式。重新读取图片会清除旧的匹配证据与恢复记录，保留当前变换。

匹配完全在本机使用 OpenCV SIFT 和稳健几何估计完成，无需下载模型。适用于具有足够细节的同源图片，包括旋转、等比缩放、裁剪及部分局部修改；细节不足、重复图案歧义或变换超限时保留当前对齐并说明原因。误差数字是验证点的中位配准误差，不是修改比例或置信度。对应点不能代表完整区域边界，未匹配区域也不等于被删除或遮挡。首版不自动处理透视、翻转、非等比拉伸或多个独立移动／拼接区域；可继续使用手动操作。

**相似区域：** 智能对齐成功后，点击 **相似区域**，后台核验后，虚线标出两图的完整几何对应范围，低透明度填色标出核验后的相似内容。范围内仍可能有修改，虚线本身不表示全部相同。此开关默认关闭，开启后持续显示；点击编号或前后箭头可联动强调左右对应部分。并排视图适合同时核对两边；滑动对比的标注随分界显示各侧，叠加和像素差异视图跟随当前“拖动哪张图片”的选择显示该侧证据。关闭即可恢复原图显示，已完成结果会在当前标签缓存；重新对齐、读取图片或恢复对齐前状态会清除旧结果。

相似区域表示**预览中局部纹理与颜色差异较小的近似范围**，允许小幅中性亮度偏移，不保证像素完全相同。可靠对齐后，相同的平坦背景也会接入有纹理证据支持的连续区域，纯裁剪不再只显示零散细节。低纹理部分使用严格的绝对颜色检查，不单独推断匹配。标注保留已检测修改处的孔洞；透明、未通过核验和零碎证据可能不标注，最多显示 12 个较大区域，**未标注不等于不同**。更细的修改请结合滑动对比或像素差异查看。标注只影响显示，不写入图片，也不会改变手动对齐参数。[区域分析设计](architecture/image-similarity-regions.md)

Choose **Smart Align** to align the right image to the original left image using scale, rotation and position. A successful estimate switches Side by Side to Wipe; other modes remain unchanged. **Match Points** shows a small numbered sample of verified correspondences. Continue refining manually or use **Restore Alignment** to recover the previous transforms, aspect locks and comparison mode. Reload clears old match evidence and the restore snapshot while retaining the current transforms.

Matching runs locally with OpenCV SIFT and robust geometry, without model downloads. It handles sufficiently detailed versions of the same image, including rotation, proportional resizing, crops and some local edits. Insufficient or ambiguous evidence and unsupported transforms leave your alignment unchanged. The reported error is the median registration residual, not the edited fraction or a confidence score. Points are not complete region boundaries, and unmatched areas do not establish deletion or occlusion. Automatic perspective, reflection, nonuniform scaling and independently moved/composited regions are outside this first version; manual controls remain available.

**Similar Regions:** After successful alignment, choose **Similar Regions** to see a dashed outline of the full geometric correspondence and translucent fills for verified similar content. The dashed outline does not claim that all content inside is the same. The toggle defaults off and stays on until hidden. Click a numbered region or use the previous/next arrows to highlight both counterparts. Side by Side shows both; Wipe clips each side's evidence at the divider; Overlay and Pixel Difference show the evidence for the selected Image to Move. Completed results are cached in the tab; a new alignment, reload or Restore Alignment clears them.

These are approximate preview regions with similar texture and small color differences, allowing modest neutral brightness shifts, **not proof of identical pixels**. After reliable alignment, strictly color-verified flat backgrounds can join texture-supported regions, keeping an unedited crop continuous. Flat patches cannot establish a match independently and receive no local brightness compensation. Detected holes remain unfilled. Transparent, unverified or fragmented evidence may remain unmarked; up to 12 larger regions are displayed. **Unmarked does not mean different.** Use Wipe or Pixel Difference to inspect fine edits. The overlay never writes source files or changes manual transforms. See the [analysis design](architecture/image-similarity-regions.md).

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

**摄影插件 Photography 0.1.0。** Full 预装，同版本 Base 可安装独立摄影包。0.15.1 应用包含下述摄影分析能力。安装并启用后，选择 **新建… → 摄影**，分别选择两张照片。普通图片的自动打开仍使用基础图片比较，摄影入口需显式选择。

**Photography 0.1.0.** Full bundles this plugin; a matching Base host can install its standalone package. The 0.15.1 app includes the photography analysis features described below. Enable the plugin, choose **New… → Photography**, and select the two photographs. Ordinary automatic image opening continues to use basic image comparison.

默认以双图和 **Lab 感知明度 L*** 直方图为主。摘要显示 L* 中位数、P90−P10 明度跨度和低／高明度区域占比；这些数值描述当前选区，不代表曝光调整值或作品质量。**专业图表**保留 HSL、实际记录的处理曲线以及拍摄与分析信息。Lab L* 的范围是 0–100，与 HSL 明度 L 分开；两者均不是物理亮度或曝光值。

The default view pairs the photographs with **Lab perceptual lightness L*** histograms. Summaries show median L*, the P90−P10 lightness span, and low/high-lightness shares for the current regions; they do not represent exposure adjustments or quality scores. **More Analysis** retains HSL distributions, recorded processing curves, and capture/analysis information. Lab L* uses a 0–100 scale and remains separate from HSL lightness L. Neither is physical luminance or exposure.

从 0.15.0 起，**专业图表默认展开**，可直接切换影调、色彩 · HSL、处理曲线和拍摄与分析信息。点击“收起专业图表”可回到简洁视图；当前视图中的重新分析、语言与外观切换保留收起状态。

From version 0.15.0, **professional charts start expanded**, with Tone, Color · HSL, Recorded Curves, and Image & Analysis available directly. **Hide Details** returns to the compact view. Reanalysis, language changes and appearance changes preserve your collapsed choice within the current view.

- **照片显示通道 / Photo display channel:** 默认显示原图，也可把红、绿或蓝通道显示为灰度图；灰度表示该 sRGB 通道的强度。它与下方直方图通道独立，不重新计算区域统计。The original image is the default. Red, green, or blue can be shown as grayscale sRGB channel intensities, independently of the chart channel and without recalculating region statistics.
- **直方图 / Histograms:** 选择感知明度、RGB 总览或单个 RGB 通道；RGB 总览分为红、绿、蓝三图。直方图默认分开显示两侧，点击“叠加”按钮后切换为叠加；分开、叠加和差值使用一致的横轴；A／左侧用蓝色实线，B／右侧用橙色虚线。差值图为右减左：蓝色表示 A 占比更高，橙色表示 B 占比更高，单位为百分点。悬停在同一分箱位置联动读取两侧占比。Select perceptual lightness, an RGB overview, or one RGB channel. The overview has separate red, green, and blue plots. Histograms show the two sides separately by default; click Overlay to combine them. Separated, overlay, and difference layouts share their horizontal scales. A/left is solid blue and B/right is dashed orange. The difference plot shows right minus left in percentage points: blue means a higher fraction in A, orange a higher fraction in B. Hover reads both sides at the same bin.
- **图表高亮 / Chart highlight:** 在直方图中拖选一段范围，在当前照片选区内部高亮匹配的预览像素；点击“清除高亮”还原。高亮使用最长边 2048 的显示预览定位；源区域统计独立采样、最长边可达 4096，因此细小纹理或边缘的高亮覆盖可能与统计占比略有不同。高亮不改变框选、统计或源文件，也不随会话保存。Drag a histogram range to highlight matching preview pixels inside each active photo region. Clear Highlight restores the preview. Highlighting uses the display preview, capped at a 2048 px longest edge. Region statistics are sampled independently at up to a 4096 px longest edge, so highlight coverage on fine textures or edges can differ slightly from the reported fractions. Highlighting does not change regions, statistics, or source files, and is not saved with the session.
- **拍摄参数 / Capture metadata:** 快门、光圈、ISO、焦距、镜头等按字段左右对照；未记录的值明确显示缺失，不根据像素推测。Shutter speed, aperture, ISO, focal length, lens, and other recorded fields are compared side by side. Missing records stay explicit rather than being inferred from pixels.
- **框选区域 / Select regions:** 在照片上拖动矩形，松开后重新统计。左右默认独立，可在不同位置选择天空或肤色等可比内容；不修改源照片。Drag a rectangle and release to analyze it. Each side is independent by default, so matching subjects may occupy different positions.
- **联动选区 / Link Regions:** 开启后，之后的框选在两图使用相同的归一化位置与比例；不是物体识别或自动配准。Future selections share normalized coordinates and proportions, without object recognition or registration.
- **保存区域 / Save Region Pair:** 点击加号、命名，最多保存 32 组左右配对；通过“已存区域”切换或删除。区域、所选 XMP 路径、照片显示通道与直方图通道／布局随本机会话保存。旧会话缺少显示偏好时默认恢复原图、感知明度与分开布局；已保存的布局按原选择恢复。Use the plus button to name up to 32 pairs, then switch or delete them in Saved Regions. Region pairs, selected XMP paths, photo display channel, and histogram channel/layout persist with the local session. Older sessions without display preferences default to the original image, perceptual lightness, and separated layout; saved layouts are restored as previously selected.
- **全图 / Whole Image:** 清除当前框选并重新统计全图，不删除已存区域。Clears active selections without deleting saved pairs.
- **处理曲线 / Recorded Curves:** 显示图片内嵌或手动选择的 Adobe CRS XMP 控制点；选择旁路 XMP 时以该记录为准。连线只作示意，不复现原软件插值、显影或调色效果。不存在记录时显示“未记录处理曲线”。Shows actual embedded or explicitly selected Adobe CRS XMP control points; a selected sidecar takes precedence. Lines are illustrative, not the original editor’s interpolation or rendering. Missing records remain missing.
- **重新读取 / Reload:** 重新加载照片并分析。查看预览的缩放相对于显示预览像素，不能当作原图 100% 细节。Reloads photographs and statistics. Inspector zoom is relative to preview pixels, not 100% original-image detail.

Apple ImageIO／Core Image 读取普通图片和颜色配置，`CIRAWFilter` 以 Apple 默认设置显影 RAW。常见 RAW 后缀包括 DNG、CR2／CR3、NEF、ARW、RAF、RW2、ORF 等，但支持依赖**具体机型、编码模式和 macOS 版本**；后缀可选不代表可解码。失败时明确报错，不用内嵌预览冒充完整 RAW。默认显影不等于相机原始采样值或原作者调色结果。

Apple ImageIO/Core Image reads ordinary images and color profiles; `CIRAWFilter` renders RAW with Apple defaults. Common RAW extensions include DNG, CR2/CR3, NEF, ARW, RAF, RW2 and ORF, but support depends on the **camera, encoding mode and macOS version**. An accepted extension is not a decoding guarantee. Unsupported RAW fails explicitly without substituting an embedded preview. Default rendering is neither raw sensor samples nor the creator’s final edit.

分析使用统一的 **sRGB 浮点 SDR 0–1** 数据，OpenCV 4.12.0 提供 Lab／HSL 转换和直方图。超范围数值截至端点，不能以此判断 RAW 过曝；完全透明和非有限像素排除，其余有效像素等权，HSL 饱和度低于 2% 的像素单独记作中性色并排除出色相分布。直方图按有效像素占比归一化，不因选区大而自动更高。

Analysis uses **floating-point sRGB SDR values in 0–1**, with OpenCV 4.12.0 providing Lab/HSL conversion and histograms. Out-of-range values are clamped, not interpreted as RAW overexposure. Fully transparent and non-finite samples are excluded; other valid pixels receive equal weight. HSL saturation below 2% counts as neutral and is excluded from hue bins. Histograms show fractions of valid pixels, so larger selections do not automatically produce taller charts.

每张照片上限 **256 MiB／6400 万像素**。显示预览最长边 **2048**；统计直接来自颜色管理后的源图选区，最长边超过 **4096** 时采用有界采样，并显示采样状态及尺寸。多帧文件只分析首帧。波形、RGB Parade、矢量示波图、噪声／锐度评分、HDR 专业分析、报告导出和照片编辑不在此版范围内。

Each photograph is limited to **256 MiB and 64 megapixels**. Display previews have a **2048 px** longest edge. Statistics use the color-managed source region, with bounded resampling above a **4096 px** longest edge and an explicit sample indicator/dimensions. Only the first frame is analyzed. Waveforms, RGB parade, vectorscopes, noise/sharpness scores, professional HDR analysis, report export and photo editing are not included.

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

提供三种页面配对方式：

- **按页码（默认）：** 第 1 页对第 1 页，依次比较；多出页面显示为单侧页，不据此断言版本新增或删除。
- **智能匹配：** 适合同一文档的不同版本。使用唯一预览或有信息量的文字寻找顺序一致的对应；证据不足、重复或歧义时明确提示并按页码比较。它不做 OCR 或语义理解，不能保证所有推断配对正确。
- **手动配对：** 两侧分别输入页码或点击前后页，页面预览与文字差异都跟随所选原始页。当前标签保留选页，切换模式后可返回继续；不新增跨重启恢复手动设置的承诺。无效页码提交后恢复当前页。

顶部“第 N / M 组”是比较组位置，两侧文件名下显示各自原始页码。匹配锚点之间缺少明确对应证据的页面仍按相对顺序展示，可用手动配对检查。手动选页限已读取的前 200 页。

Choose each side through New… → PDF Documents, or open two PDFs through File → Open… or Compare → PDF Comparison…. Page view retains page layout and the sidebar shows corresponding pages. Switch to Text Differences for extracted text, navigate changes, or zoom the page. Scanned pages and extraction limits are indicated; OCR is not included. The view is read-only.

CrossDiff offers **By Page** (default), **Smart Match** and **Manual Pairing**. Page order compares the same original page numbers without inferring revision history. Smart Match uses unique preview or informative text evidence for related revisions; insufficient or ambiguous evidence falls back to page order with an explanation. It does not perform OCR or semantic analysis, and pages between reliable anchors may still be paired by relative order.

Manual Pairing provides independent page-number fields and previous/next controls on each side. Page previews and text differences follow the selected source pages. Choices remain in the current tab when switching tabs or pairing modes; manual settings are not newly persisted across app restarts. Invalid entries revert to the current page. **Pair N / M** identifies the comparison group; source page numbers appear under the file names. Selection is limited to the pages read (at most 200 per side).

在“CrossDiff → 插件…”管理扩展：选择／拖入 `.crossdiffplugin` 文件，或输入 HTTPS 链接点击“下载并检查”。检查名称、标识、版本、未验证发布者与运行权限后安装。任意链接下载需先检查再安装。重复安装同一个版本但内容不同会被拒绝；更新请使用新的版本号。

Manage extensions under CrossDiff → Plugins…: choose or drop a `.crossdiffplugin` file, or enter an HTTPS URL and click Download & Inspect. Review the name, identifier, version, unverified publisher and runtime permissions before installation. Downloads from arbitrary URLs require review before installation. Changed packages must use a new version number.

官方插件列表随应用提供，离线可查看。点击“下载并安装”后，应用从固定版本的 GitHub Release 下载，核对整包 SHA-256、大小、标识和版本，再自动安装受限插件。基础版内置压缩包与 Git 插件；完整版额外预装 PDF、摄影、API、音频、办公与视频。基础版可在“发现插件”页下载并安装兼容插件，也可导入对应 Release 的独立包。插件下载与远程 Git 获取仅在主动操作时联网，比较内容仍在本机处理。

The official catalog is bundled and available offline. Download & Install fetches a version-pinned GitHub Release asset, verifies its complete SHA-256, size, identifier and version, then installs the restricted plugin. Base bundles Archive and Git. Full adds PDF, Photography, API Compare, Audio, Office and Video. Base can download and install compatible plugins from Discover, or import standalone packages from the matching Release. Plugin downloads and remote Git retrieval connect only on request; comparison content stays on your Mac.

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

**English:** Choose **New… → Audio** and select two local files. Full bundles Audio 0.1.0; a matching Base host can install its standalone package. Inspect per-channel waveforms or calibrated STFT spectrograms, select and save up to 32 region pairs, and audition A/B or loop a region. Audition supports mono/stereo. B has independent rate and pitch controls; these never rewrite the source. Find Matches uses a bundled Olaf helper for fixed-speed excerpts of the same recording, including reordered and repeated candidates. Automatic recognition of independent tempo or pitch changes is not currently supported. Unmatched regions are not proof of deletion. Analysis accepts up to 2 GiB, two hours and eight channels per side; three-to-eight-channel files remain available for waveforms, spectra and comparison, without audition. Codec support is probed by macOS. Waveforms are bounded overview envelopes. Spectra analyze at most the first 30 seconds of the selected region at 48 kHz, with smaller explicit ranges for dense settings. All comparison remains local.

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

<a id="video"></a>

## 视频对比 / Video Compare

**Video 0.1.0。** 0.15.1 Full 预装；同版 Base 可在“发现插件”页下载并安装，或导入对应 Release 的独立 `.crossdiffplugin` 包。从 **新建… → 视频** 选择两个本地 MOV、MP4 或 M4V 文件；格式能否播放由 macOS 实际解码能力决定。

- 默认双画面、双时间线；点击时间线定位。点击画面后，用 **空格** 播放／暂停，**← / →** 逐帧；A/B 选择逐帧的基准侧。对应命令也在“比较”菜单中。
- 默认按同时间联动，这不代表内容已匹配。关闭联动分别找对应画面，然后在 **时间对齐… → 将当前两帧设为对应** 配对。也可输入偏移：`B 时间 = A 时间 + 偏移`。调整支持撤销／重做。
- 默认静音；选择 A 或 B 只试听一侧。联动时可设置两侧有效重叠范围内的循环片段。
- **滑动**和**差异**在暂停帧上工作；播放自动回到并排。差异图要求两侧明确标记为 Rec.709 SDR，且缩略解码画面或所选区域尺寸相同。它是视觉预览，不是编码质量评分；HDR、色彩标记缺失或尺寸不同可继续视觉对照。
- 暂停后用框选按钮分别选择区域；在旁边菜单启用区域联动或保存命名区域，最多 32 组。点击恢复按钮回到全图。框选不会裁剪或修改原视频。
- 信息按钮显示源时长、尺寸、标称帧率、编码、音轨与色彩标签，并提供重新读取。逐帧使用真实样本时间；无法确认精确帧时会明确提示。

位置、偏移和区域在本机会话中恢复；切换标签或关闭比较会停止播放。原视频始终只读。首版不含自动剪辑匹配、视频导出或实时播放差异。

**English.** Choose **New… → Video** and select two local MOV, MP4 or M4V files. The 0.15.1 Full edition includes Video 0.1.0. A matching Base host can use Download & Install in Discover, or import the standalone `.crossdiffplugin` package from the corresponding Release. Click either timeline to seek, then focus a frame to use **Space** and the **Left/Right arrows**. A/B chooses the reference for frame stepping. Unlink to find corresponding frames independently, then use **Time Alignment… → Pair Current Frames**, or enter `B time = A time + offset`. Undo/redo restores viewing adjustments.

Playback starts muted; choose A or B to hear only that source. Looping requires linked browsing and a range that exists in both videos. Wipe and difference inspect paused frames; playing returns to side-by-side. The difference preview requires explicit Rec.709 SDR tags and equal decoded/cropped dimensions. It is not a codec-quality score. Pause to select independent or linked regions and save up to 32 named pairs. Positions and viewing choices stay in the local session; switching tabs stops playback. Original media is never modified. Automatic edit matching and video export are not part of this milestone.


<a id="git"></a>
## Git 仓库 / Git repositories

**新建…** 依次显示文本、文件夹、图片、Git、二进制、压缩包，其余项目顺序不变；停用或移除的插件隐藏。选择 **Git** 后，可选择本地仓库，或输入 GitHub、GitLab、Gitee、自建 Git 服务的 HTTPS／SSH 克隆地址。0.15.1 的 Base 与 Full 均内置 Git 插件。运行需要系统 Git（Apple Command Line Tools 提供），应用不会自动安装工具。

**本地仓库默认显示“全部未提交”。** 无需先 commit 或 stash：

| 快捷入口 | 左侧 → 右侧 | 用途 |
| --- | --- | --- |
| 全部未提交 | HEAD → 工作区 | 当前文件相对上次提交的全部变化，包含已暂存和未暂存的最终内容 |
| 已暂存 | HEAD → 暂存区 | 已通过 `git add` 准备放入下一次提交的内容 |
| 未暂存 | 暂存区 → 工作区 | 尚未 add 的修改，包括 add 后再次编辑的部分 |

也可在两侧来源菜单自由选择“提交／分支”“暂存区”“工作区”，例如比较某个发布分支与当前工作区。没有首次提交时，HEAD 显示为空基准；远程缓存和裸仓库仅支持提交来源。选择快捷入口立即比较，自定义提交输入修改后点击“比较”。已打开的旧会话保留原来的两个提交。

“包含未跟踪文件”默认开启，可在选项中关闭；遵循 `.gitignore`、`.git/info/exclude` 等可用忽略规则，不加载全局 Git 配置。暂存区和工作区都只读，不提供 add、reset 或 commit。显示的是上次比较时的快照；文件变化后点击“刷新”。若选中文件已不同于扫描时的内容，会提示刷新，不混用旧树和新内容。

打开后在两侧版本选择器选择分支、标签或最近提交，也可以输入提交哈希。选择提交来源时，版本会解析为固定提交，再读取对象快照；不会切换当前分支或改动原仓库、索引。选择工作区来源时会读取当前未提交的内容。左侧目录树默认仅差异，可切换全部文件并搜索路径；选择文件后右侧显示成对内容、原生行号、字符差异和对齐的行。文本可选择、复制、查找（⌘F／⌘G／⇧⌘G），不支持编辑或写回历史。

- **重命名识别**：默认开启，Git 相似度阈值 50%；关闭后移动表现为删除与新增。超过 1,000 个候选时，Git 可跳过昂贵的近似匹配，部分移动仍显示为删除与新增。暂存区／工作区参与比较时仅匹配内容完全相同且一一对应的重命名。
- **共同祖先**：将两版本的共同祖先与右侧版本比较，适合审查某分支从分叉点以来的变化；普通模式直接比较左右两个提交。界面显示实际提交短哈希。
- **文本查看**：换行、同步滚动、字符高亮、忽略空白和大小写仅影响详情视图；文件树仍依据完整对象与文件模式判断是否变化。
- **非文本对象**：二进制显示前 64 KiB 的 Hex 预览，明确提示预览范围；符号链接显示目标文字，子模块显示固定提交号，不跟随链接、不展开子仓库；Git LFS 显示已提交的指针，不自动下载外部内容。
- **范围**：仓库扫描不设固定的单文件大小、总大小或文件数量上限；每侧文件预览最多 2 MiB，超限显示提示，不以截断文本冒充完整比较。最近提交列表最多 200 条，较早的提交可直接输入哈希。不提供冲突解决或 Git 写入操作。暂存区有未解决合并阶段时明确提示，不猜测冲突版本。

远程仓库首次打开时下载完整仓库历史到应用自己的本机缓存，不 checkout；大型仓库可能需要较长时间，可随时取消，单次下载超时为 5 分钟，缓存软限额为 2 GiB／200,000 项；之后只在点击刷新时 fetch。恢复会话时不会自动联网，缓存缺失需要明确重新连接。HTTPS 支持公开仓库，SSH 使用现有密钥和已信任主机，不自动接受主机指纹或弹出认证；私有 HTTPS 仓库请先用自己的 Git 工具克隆，再选择本地目录。不会保存 URL 中的令牌或密码，不执行仓库 hooks、外部 diff 或 textconv。

**New…** starts with Text, Folders, Images, Git, Binary and Archives; remaining items keep their order, and disabled or removed plugins stay hidden. Choose **Git**, then a local repository or an HTTPS/SSH clone URL. Working repositories, bare repositories and worktrees are supported. Git is bundled as a plugin in Base and Full from version 0.15.0. System Git from Apple Command Line Tools is required and is never installed automatically.

New local sessions default to **All Uncommitted** (HEAD → working tree). **Staged** compares HEAD → index, showing what `git add` prepared for the next commit. **Unstaged** compares index → working tree, isolating edits made after staging. Each side can also choose Commit / Branch, Staging Area or Working Tree independently. Presets compare immediately; custom revision edits use Compare. Earlier sessions keep their two commit sources. An unborn HEAD becomes an explicit empty baseline; bare repositories and remote caches offer committed revisions only.

Include Untracked Files defaults on, respecting `.gitignore`, `.git/info/exclude` and other available exclusion rules without loading global Git configuration. These are read-only snapshots: no staging, reset or commit actions. Refresh rereads local changes; if a file differs from its captured identity/content when selected, the app asks for a refresh instead of mixing new content with an old tree.

Select branches, tags, recent commits or enter a commit hash. Both selections resolve to fixed commits without checkout or changing the index or working tree. The narrow file tree offers changes-only/all-files and path filtering; select a file for paired read-only text, line alignment, character highlights and Find (⌘F/⌘G/⇧⌘G). Copying is supported; editing history is not.

Rename detection defaults to a 50% similarity threshold. Git may skip expensive inexact matching above 1,000 candidates, leaving some moves as additions/deletions. Merge-base mode is available only for two committed revisions and compares the common ancestor against the right revision. Local-source rename matching is limited to unambiguous, byte-identical contents. Whitespace, case and wrapping options affect text detail only, while file status reflects the complete objects and file modes. Binary files show a labeled first-64-KiB Hex preview; each blob preview is limited to 2 MiB, and recent history to 200 entries. Repository scans have no fixed per-file size, total-byte or file-count ceiling. Older commits can be entered by hash. Symlinks, submodules and LFS pointers remain committed records and are not followed or downloaded.

Remote repositories are downloaded only when explicitly opened and refreshed only on request, into a local application cache without checkout. Full history can take time to download; cancellation is available, with a five-minute deadline and polled soft limits of 2 GiB / 200,000 cache entries. Session restoration never initiates a download. HTTPS supports public repositories; SSH uses existing keys and trusted hosts without accepting new host keys or prompting. Clone private HTTPS repositories with your own Git client first, then open them locally. URLs containing credentials are rejected. Repository hooks, external diff and text conversion commands are not executed.

本地快照边界 / Local snapshot boundaries:

- 工作区按磁盘原始字节读取，不执行 `.gitattributes` clean/smudge、LFS 或换行转换。采用这些转换的仓库可能显示磁盘与已暂存字节的差异。子模块仅显示暂存的提交指针，不分析嵌套工作区；稀疏检出中缺失的 skip-worktree 文件保留其索引内容。
- 仓库目录逐条读取，工作区文件分块计算摘要，插件按文件对分批核验；取消原有单文件 256 MiB、总计 1 GiB、50,000 个文件及扫描总时长的固定限制。比较在后台进行且可取消，状态栏显示扫描文件数、读取量和分批核验进度；耗时与实际文件量和磁盘速度有关，目录元数据仍需内存。详情预览独立保留每侧 2 MiB 上限。不支持的特殊文件、取消或读取失败不会作为完整结果发布。
- Working files are read as raw bytes, without clean/smudge filters, LFS or line-ending conversion. Repositories using those conversions may show differences between on-disk and staged bytes. Submodules retain the index's commit pointer without inspecting nested working changes. Missing skip-worktree paths in sparse checkouts retain their indexed content.
- Directory records are streamed, working files are hashed in chunks, and the plugin validates file pairs in batches. The former 256 MiB per-file, 1 GiB total, 50,000-file and total scan-time limits are removed. Background scans remain cancellable; the status bar reports scanned files, bytes read and batch validation progress. Time depends on file volume and disk speed, and directory metadata still uses memory. Detail previews separately retain their 2 MiB-per-side budget. Unresolved index stages, unsupported special files, cancellation or read failures never publish an incomplete comparison as a complete one.

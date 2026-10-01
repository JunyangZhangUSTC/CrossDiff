# Using CrossDiff

CrossDiff compares text, folders, images, binary files, archives and PDF documents on your Mac. There is no sign-in. For build instructions, see the [development guide](development.md); for planned formats such as Word and spreadsheets, see the [roadmap](roadmap.md).

## Start a comparison

Click **New… / 新建…** (`⌘N`) in the toolbar or File menu. Choose a comparison type, then prepare the left and right inputs on the next page and start the comparison. Text accepts temporary pasted content or a file on each side. Folder, image and binary comparisons accept the corresponding sources; archive and PDF comparisons appear when their bundled plugins are enabled. **More Comparisons / 更多对比项** opens plugin management. The **Compare** menu goes directly to the input page for a chosen type.

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

## Compare folders

Folder comparisons scan recursively and show changed, matching, one-sided, unreadable, and type-mismatched entries. `.git`, `.build`, `node_modules`, and `.DS_Store` are ignored by default.

Select a regular file to copy it in either direction. CrossDiff first lists planned additions and overwrites, then checks the inputs again before executing. It does not perform full synchronization or batch deletion and does not follow or copy symbolic links. If a copy sequence fails partway through, completed copies remain; compare the folders again before continuing.

<a id="archives"></a>
## Compare archives / 压缩包比较

Choose **Compare → Archive Comparison… / 比较 → 压缩包比较…**, then select two archives, or an archive and a local folder in either order. The normal **Open…** and drag-in pairing paths also recognize compatible archive/folder pairs. For more than two inputs, explicitly assign the pairs. The official archive plugin is included and enabled by default; it can be disabled in **CrossDiff → Plugins…**. An explicitly selected archive comparison also accepts two local folders under these read-only content-comparison rules.

Supported formats: ZIP (stored/deflate), TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2 and TAR.XZ/TXZ. Extension alone does not prove a valid format. Gzip, bzip2 and xz streams must contain TAR. RAR, 7z, encrypted archives, multi-volume archives and recursive expansion of nested archives are not supported. ZIP64, non-UTF-8 names and ZIP Unicode-path override extra fields are currently outside the supported ZIP subset. XZ accepts a single stream without trailing stream padding, with one LZMA2 filter per block and at most a 64 MiB dictionary. CRC32, CRC64 or SHA-256 checks are required; the index is capped at 1 MiB, with at most 10,000 blocks and 100,000 chunks.

**By Path / 按路径** presents an expandable native directory tree. A file is **Same** only when its length and SHA-256 digest match; timestamps and permissions are not compared. Directories summarize their descendants, preserving empty directories. Use the path filter and **Changes Only / 仅差异** to focus the tree; ancestors remain available. **Same Content / 相同内容** groups verified matching files at different paths across the two sources, keeping every member without generating a Cartesian list. This is evidence of identical contents, not an inferred rename or move.

The operation is read-only: compressed contents are decoded as bounded streams in memory, **without extracting files to disk**. Nested archives are ordinary files. Symbolic links, hard links and special entries are never followed and remain **Unverified**; their targets are not considered equal. Corruption, encryption, unsafe paths, conflicting or duplicate entry paths, and reading limits stop the comparison rather than produce a misleading match. Source changes detected before publication or cached reuse invalidate the result; choose Reload to scan again. This is change detection, not an immutable filesystem snapshot.

Each side allows up to **10,000 entries** including implicit directories, **512 MiB** of expanded data, **256 MiB** per file, and **2 GiB** per compressed archive. Paths are limited to **4096 UTF-8 bytes** and **128 components**. TAR has an additional **544 MiB** decoded-stream cap, allowing at most 32 MiB above the content budget for headers and padding. Local folder comparison through this plugin includes hidden files and uses the same content budgets; it does not inherit the normal folder comparison's ignore list. Path matching is case-sensitive and treats canonically equivalent Unicode names as the same path; ambiguous names in one archive are rejected.

There is no extraction, contained-file editing, merge, copy-back or export action in this release. Saved sessions retain source paths and plugin identity, not expanded file bytes. For byte-level differences in the archive file itself, use **Binary Comparison…** instead.

## Compare images

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

All adjustments are manual and affect previews only; CrossDiff does not automatically register images, apply perspective or free-form warping, or write the transformed result to either source file. Alignment and viewing state survive switching comparison tabs in the current app session, but image alignment is not restored after restarting the app.

Comparison uses an 8-bit sRGB preview with a maximum 1600-pixel longest edge. Images are decoded at a shared scale, and an enlarged or rotated canvas is reduced again if needed. Zoom and difference counts refer to these previews, not to a full-resolution lossless analysis. Scaling, rotation, resampling, and source compression can leave small differences even after visual alignment. Only the first frame of animated images is compared.

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

Choose each side through New… → PDF Documents, or open two PDFs through File → Open… or Compare → PDF Comparison…. Page view retains page layout and the sidebar shows corresponding pages. Switch to Text Differences for extracted text, navigate changes, or zoom the page. Scanned pages and extraction limits are indicated; OCR is not included. The view is read-only.

在“CrossDiff → 插件…”管理扩展：选择／拖入 `.crossdiffplugin` 文件，或输入 HTTPS 链接点击“下载并检查”。检查名称、标识、版本、未验证发布者与运行权限后安装。任意链接下载需先检查再安装。重复安装同一个版本但内容不同会被拒绝；更新请使用新的版本号。

Manage extensions under CrossDiff → Plugins…: choose or drop a `.crossdiffplugin` file, or enter an HTTPS URL and click Download & Inspect. Review the name, identifier, version, unverified publisher and runtime permissions before installation. Downloads from arbitrary URLs require review before installation. Changed packages must use a new version number.

官方插件列表随应用提供，离线可查看。点击“下载并安装”后，应用从固定版本的 GitHub Release 下载，核对整包 SHA-256、大小、标识和版本，再自动安装受限插件。基础版内置压缩包插件；完整版额外预装 PDF。基础版可以在此单独安装 PDF。联网只发生在你主动下载时，比较内容仍在本机处理。

The official catalog is bundled and available offline. Download & Install fetches a version-pinned GitHub Release asset, verifies its complete SHA-256, size, identifier and version, then installs the restricted plugin. Base bundles Archive; Full additionally bundles PDF. Base can install PDF here. Network access occurs only when you request a download; comparison content stays on your Mac.

停用或卸载后，会话保留并提示需要对应插件。外部插件更新后可回退至上一版本。内置 PDF 的更新随应用分发，不能由外部同名标识覆盖。

Disabling or uninstalling retains comparison sessions. External plugin updates can roll back to the previous version. Bundled PDF updates ship with the app; external packages cannot override its identifier.

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

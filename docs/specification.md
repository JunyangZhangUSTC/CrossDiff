# CrossDiff 产品规格

初始范围与后续版本决策共同构成产品约束；当前开发预览为 0.4.0。实现入口、运行方式和已知边界以 [README](../README.md) 为准。

## Confirmed product decisions

CrossDiff is an open-source, local-first macOS comparison application without accounts or authentication. Prioritize native Mac interaction using SwiftUI and AppKit.

The most important workflow is pasting two temporary texts and seeing precise differences, including Chinese, punctuation and numbers. Code files and code directories follow. Deliver text, folders and images first; prioritize research-paper PDF comparison in the following milestone, then structured documents and spreadsheets.

- Use the focused two-column layout. Comparison types belong in the macOS menu bar. The toolbar starts with **Open…**, not a comparison-type dropdown.
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

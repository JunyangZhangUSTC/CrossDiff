# Using CrossDiff

CrossDiff compares text, folders, and images on your Mac. There is no sign-in. For build instructions, see the [development guide](development.md); for planned formats such as PDF and spreadsheets, see the [roadmap](roadmap.md).

## Start a comparison

Paste text directly into the two panes, or choose **Open…** (`⌘O`) to select files or folders. Two compatible items open as a comparison. When you select more items, assign explicit left/right pairs before opening each comparison in its own tab.

The **Compare** menu contains the comparison types. **File → New Text Comparison** (`⌘N`) creates a blank text comparison.

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

## Compare images

Choose **Side by Side**, **Overlay**, **Wipe**, or **Pixel Difference**. Drag the wipe divider to inspect corresponding areas, or adjust zoom. Images of different sizes share a common canvas rather than being stretched independently to match.

Comparison uses an 8-bit sRGB preview with a maximum 1600-pixel longest edge. Zoom and difference counts refer to the preview, not to a full-resolution lossless analysis. Only the first frame of animated images is compared.

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
| New Text Comparison / Open | `⌘N` / `⌘O` | File |
| Save Current Side / Save As | `⌘S` / `⇧⌘S` | File |
| Close Comparison or Window | `⌘W` | File |
| Settings | `⌘,` | CrossDiff |

When a search field is focused, editing commands operate on that field. When Settings is in front, they do not modify a comparison behind it.

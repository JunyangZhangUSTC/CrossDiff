# 0.3.0 本地验收记录

日期：2026-10-01。产物：`dist/CrossDiff.app`，版本 `0.3.0`，构建号 `7`。

## 本轮交付

- AppKit 管理原生窗口和菜单；编辑命令跟随当前窗口及输入焦点，菜单展示对应快捷键。
- 查找、前后匹配、使用选区查找、当前及全部替换；收起查找栏后仍可通过 ⌘G / ⇧⌘G 继续查找。
- 独立设置窗口，English / 简体中文即时切换，语言和浅深色外观在本地保存。
- 应用菜单、文本、文件夹、图片、提示及错误文案双语；切换语言保留原文、编辑器与撤销记录。

## 已完成检查

| 命令 | 结果与覆盖 |
| --- | --- |
| `bash scripts/check.sh` | 通过：既有差异、合并、投影、目录与存储回归；新增偏好/翻译、Unicode 字面替换、超过导航上限的全量替换、结果大小限制与取消 |
| `bash scripts/tests/check-editor.sh` | 通过：独立撤销、标签恢复、组合输入、颜色、原生字形与高亮、预览滚动 |
| `bash scripts/tests/check-alignment.sh` | 通过：对齐占位、中文/emoji/CRLF、换行、选区、撤销与查找时输入位置 |
| `bash scripts/tests/check-scroll-geometry.sh` | 通过：首行/首列、行号占位、窗口缩放、长文本滚动 |
| `bash scripts/tests/check-deletion-preview.sh` | 通过：默认关闭、红色删除线真实像素、预览切换、保存隔离与浅深色宽窄窗口 |
| `bash scripts/tests/check-workflow.sh` | 通过：完整原生窗口中的合并、搜索、替换、保存恢复、清空恢复、菜单键盘事件、查找框撤销隔离、设置窗口焦点及中英文切换 |
| `bash scripts/build-app.sh` | 通过：Release 构建及项目内 app 打包 |
| `codesign --verify --deep --strict dist/CrossDiff.app` | 通过：本地 ad-hoc 签名完整性 |

`scripts/check-all.sh` 已串行完成全部六组回归。补充关闭查找栏后的导航、搜索框焦点及菜单去重后，再运行完整工作流检查。键盘验证向真实 `NSMenu` 分发 `NSEvent`，核对正文和查询的实际变化，不只检查快捷键声明。原生程序使用项目内独立会话与测试文件，不使用用户真实会话或系统剪贴板。

## 原生窗口检查

实际 AppKit 窗口树的渲染保存在 `.build-workflow-checks/renders/`，交付预览复制到 `dist/previews/`：

- `settings-zh.png`、`settings-en.png`：独立设置窗口、即时标题与选项翻译。
- `crossdiff-replace-en.png`、`crossdiff-replace-en-narrow.png`、`crossdiff-replace-en-dark.png`：英文查找替换在宽屏、860 点最小窗口和深色外观下的布局。
- `folder-en.png`、`folder-zh.png`、`image-en.png`、`image-zh.png`：中英文文件夹与图片比较。
- `menus-en.txt`、`menus-zh.txt`：实际菜单树；应用自有编辑/查找/显示菜单无重复注入条目。

视觉复核确认了正文、差异、行号和控件可见；语言切换后的原生 Picker 选项也随之刷新。保留编辑器身份，只刷新缓存标题的 Picker。

## 验证边界

- 这是本机开发包，未做 Developer ID 签名或公证，也未发布到远程。
- 系统文件选择器内部和第三方服务条目的语言由 macOS 或服务提供方决定；应用自有标题、说明和按钮遵循所选语言。
- 输入法通过文本输入接口验证，真实候选窗操作、Finder 拖放、系统文件对话框和长时间使用仍需人工验收。
- 构建不会替换已运行进程中的代码。正常退出旧版后，用 `bash scripts/open-dev-app.command` 启动新版，可让运行数据继续保留在项目内。

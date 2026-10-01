# 0.3.1 本地验收记录

日期：2026-10-01。产物：`dist/CrossDiff.app`，版本 `0.3.1`，构建号 `8`。

## 本轮交付

- 设置窗口切换浅深色时，语言选择器即时更新外观。应用菜单固定为“设置/Setting…”，设置内语言标签固定为“语言/Language”。
- 工具栏增加撤销、重做图标，沿用菜单的当前窗口和输入焦点判断，无可用操作时禁用；点击不抢走输入焦点。
- “打开…”增加轻边框和悬停反馈。
- 查找与差异跳转使用淡蓝细框和轻背景，短暂显示后淡出；遵循系统减少动态效果设置。

## 修复依据

主题问题已在原生窗口复现：窗口与宿主视图更新为深色后，语言 `NSPopUpButton` 仍保留浅色外观，反向切换同样滞后。设置内容显式传递 SwiftUI `colorScheme` 后，同一选择器即时更新。修复前后探针分别失败与通过，并检查了完整父窗口渲染中的文字像素。

导航提示只绘制展示层，不改原文、文本属性或撤销记录。删除预览沿用来源映射，右侧查找提示不包含投影插入的删除文字。空文本差异使用位置标记；连续导航会替换旧提示。

## 已完成检查

| 命令 | 结果与覆盖 |
| --- | --- |
| `bash scripts/tests/check-workflow.sh` | 通过：原生菜单与双语设置、两种语言的深浅色切换及实际文字像素；工具栏在左右正文和查找框中的撤销／重做、禁用状态及焦点；导航框的换行、多行、中文/emoji、空文本、预览来源映射、连续跳转和自动消失；既有合并、替换、复制、保存与恢复 |
| `bash scripts/tests/check-editor.sh` | 通过：独立撤销、标签恢复、组合输入、异步差异、浅深色原生字形及高亮 |
| `bash scripts/tests/check-alignment.sh` | 通过：空白占位、Unicode/CRLF、换行、选区、撤销、组合输入、滚动及查找时输入位置 |
| `bash scripts/tests/check-deletion-preview.sh` | 通过：默认关闭、源文本与撤销隔离、删除线真实像素、空右侧、合并及宽窄/浅深色窗口 |
| `bash scripts/build-app.sh` | 通过：Release 构建和项目内打包 |
| `codesign --verify --deep --strict dist/CrossDiff.app` | 通过：本地 ad-hoc 签名完整性 |

原生检查串行运行，使用项目内独立测试会话，不操作用户真实文件、会话或系统剪贴板。菜单检查在分发键盘事件前等待测试窗口实际激活；设置检查等待原生控件完成挂载，避免把测试窗口失去前台状态误判为产品失败。

最终工作流日志：`.build/validation-0.3.1-workflow-final.log`。编辑器、对齐、预览和构建日志分别为 `.build/validation-0.3.1-editor.log`、`.build/validation-0.3.1-alignment.log`、`.build/validation-0.3.1-preview.log` 和 `.build/build-0.3.1.log`。本轮未修改核心算法，未重复运行核心和独立滚动几何检查。

## 实际窗口预览

原始渲染位于 `.build-workflow-checks/renders/`，以下预览同时保存在 `dist/previews/`：

- `settings-zh-Hans-light.png`、`settings-zh-Hans-dark.png`、`settings-en-light.png`、`settings-en-dark.png`：双语标签与即时主题切换。
- `crossdiff-toolbar-light.png`、`crossdiff-toolbar-dark-narrow.png`：工具栏的浅色宽窗口和深色最小宽度窗口。
- `navigation-source-light-window.png`、`navigation-preview-dark-window.png`、`navigation-empty-side-dark-window.png`：原文、删除预览及空文本的定位提示。
- `menus-zh.txt`、`menus-en.txt`：实际菜单树，含固定双语设置入口。

已复核父窗口合成效果，正文、差异、行号、语言选择器和新按钮均可见。

## 验证边界

- 本包为本地开发预览，未做 Developer ID 签名、公证或远程发布。
- 输入法检查通过原生文本输入接口完成；真实候选窗、Finder 拖放及长时间使用仍保留人工验收。
- 已打开的旧版进程不会自动更新。正常退出旧版后，通过 `bash scripts/open-dev-app.command` 启动新版，使运行数据继续留在项目内。

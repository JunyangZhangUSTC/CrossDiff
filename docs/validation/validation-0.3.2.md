# 0.3.2 按钮布局验收

日期：2026-10-01。产物：`dist/CrossDiff.app`，版本 `0.3.2`，构建号 `9`。

“打开…”原先使用前缘图标布局，新增宽度没有形成均衡的外侧留白。启用原生 `NSButton.imageHugsTitle` 后，图标与文字紧邻并作为整体居中。保留原有尺寸、边框、点击动作与可访问性。

- 独立原生渲染通过：中文、英文 × 浅色、深色 × 1220、860 点宽度，共八种完整窗口。已查看父窗口合成效果，图标不再贴边、两侧留白均衡，英文标题完整可见。截图位于 `dist/previews/open-button/`。
- Release 构建及 `codesign --verify --deep --strict dist/CrossDiff.app` 通过。
- 未为纯布局变更新增单元测试或改动既有检查。临时渲染入口为 `.build-workflow-checks/open-spacing/render.sh`，复用项目原生窗口验收工具，所有数据与产物均在项目内。
- 完整工作流检查在“native search field redo has settled”处超时，未计为通过；不对未完成部分声称验证成功。本次独立外观验收日志为 `.build/validation-0.3.2-toolbar.log`，完整流程日志为 `.build/validation-0.3.2-workflow.log`。

这是本地 ad-hoc 开发包。正常退出旧版后，通过 `scripts/open-dev-app.command` 启动新版，运行数据继续留在项目内。

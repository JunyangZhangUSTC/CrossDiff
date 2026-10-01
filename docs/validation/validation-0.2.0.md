# 0.2.0 本地验收记录

日期：2026-10-01。全部开发文件、编译缓存、临时文件、样例、会话和渲染产物保存在 CrossDiff 项目目录内。未安装到其他项目或 `/Applications`，未推送远程仓库。

本次环境：Apple Silicon arm64、macOS 26.6.2、Apple Swift 6.3.3。部署下限仍为 macOS 14，但本轮未在 macOS 14 实机运行。

## 已通过

| 入口 | 验收内容 |
| --- | --- |
| `bash scripts/check.sh` | 196 组 Unicode/换行输入、相似行配对、无损双向合并、删除投影、两种复制表示、搜索限量及取消、后台保存顺序、编码、外部修改检测、目录复制 |
| `bash scripts/tests/check-editor.sh` | 独立撤销、标签页重绑、组合输入提交、同步滚动、白色富文本输入规范化、浅深色属性及真实可读红绿字形像素 |
| `bash scripts/tests/check-alignment.sh` | 首中尾占位、空一侧、Unicode/CRLF、不同宽度与换行、同实例缩放、对齐开关、撤销、搜索中的连续输入、拒绝未提交输入期间及过期界面快照的写回 |
| `bash scripts/tests/check-scroll-geometry.sh` | 首行首列、行号栏占位、宽窄布局、长文本滚动和选区保留 |
| `bash scripts/tests/check-deletion-preview.sh` | 默认关闭、预览焦点、原文/撤销/保存隔离、选区恢复、富文本删除线、空右侧、浅深色和窄窗口的真实像素 |
| `bash scripts/tests/check-workflow.sh` | 完整原生窗口中的点击选块→合并→撤销、两侧搜索与预览映射、连续输入、原文保存和会话恢复；复验正常退出 |
| `bash scripts/build-app.sh` | Release 应用构建、图标打包、ad-hoc 签名 |
| `codesign --verify --deep --strict dist/CrossDiff.app` | 签名校验 |

原生检查串行执行。通过程序自身的视图缓存绘制生成图片，没有截取桌面或用户的其他窗口；检查构建隔离真实系统输入法并直接测试文本输入接口。复制表示在内存中验证，未使用通用剪贴板；已有粘贴导入检查使用独立命名的测试剪贴板。

像素验收同时检查精确主题属性、实际字形的红绿颜色特征、至少 4.5 的画布对比度及像素覆盖。显示器颜色配置与抗锯齿会改变像素数值，因此不要求实际每个像素与输入 sRGB 常量相等。

AppKit 的 RTF 导出可能把分解的重音字符规范化为合成形式；富文本检查保证内容等价和删除线属性。普通原文复制、保存和会话恢复仍按 UTF-16 精确保留原文。

## 本地产物

- 应用：`dist/CrossDiff.app`，版本 0.2.0，构建号 5。
- 项目内启动：`bash scripts/open-dev-app.command`。
- 实际窗口图：`dist/previews/crossdiff-workspace.png`、`crossdiff-workspace-dark.png`、`crossdiff-workspace-narrow.png`、`crossdiff-search.png`、`crossdiff-review.png`、`crossdiff-review-narrow.png`。
- 可执行文件 SHA-256：`1008957f337e374d46e772785a3a835aafd0d689bd2351588572d167e35d4f17`。

## 尚未验证或实现

真实系统输入法候选窗、Finder 拖放、系统打开/保存面板与长时间日常使用仍需要人工验收。GitHub Actions 仅添加了配置，尚未连接远程并实际运行。应用是本地开发签名包，未进行公开发行公证；PDF、Word、表格及三方合并尚未实现。

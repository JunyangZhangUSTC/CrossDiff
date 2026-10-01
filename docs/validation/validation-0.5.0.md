# 0.5.0 插件框架与 PDF 验收

日期：2026-10-01。环境：Apple silicon（arm64）、macOS 26.6.2、Swift 6.3.3；项目以 Swift 5 语言模式和 macOS 14 部署下限构建。应用版本 0.5.0，构建号 13。

## 已完成检查

| 检查 | 本次结果 |
| --- | --- |
| `bash scripts/check.sh` | 核心文本、Unicode／换行、删除投影、查找替换、文件保存、目录与会话检查通过 |
| `bash scripts/tests/check-plugins-core.sh` | 43 项通过：协议角色、包完整性、不可变版本、启停／卸载／回退、原生内容批准、系统隔离标记和存储失败保留 |
| `bash scripts/tests/check-plugin-runtime.sh` | 实际 JS 和原生进程、缺少 I/O 桥接、输入／输出／stderr 预算、CPU／墙钟、取消、内存监测、摘要／签名／隔离和结果身份检查通过 |
| `bash scripts/tests/check-plugin-download.sh` | 离线 URLProtocol 检查通过：流式接收、16 MiB 边界、非 2xx、HTTPS 降级拒绝、取消；未访问外网 |
| `bash scripts/tests/check-plugin-manager.sh` | 损坏项显示与卸载、坏注册表保留内置能力、下载与本地预览互斥及取消恢复通过；菜单边界使用测试替身，不充当窗口验收 |
| `bash scripts/tests/check-pdf.sh` | 15 项算法与 28 项 PDF/model 检查通过：插页／删页、扫描页、同文字不同图形、部分覆盖、锁定／损坏、取消与执行身份、原文件不变 |
| `bash scripts/tests/check-plugin-workflow.sh` | 真实完整原生窗口通过：插件预览／安装／启停／卸载／会话恢复、独立 JSON 算法、内置与外部安装的相同 PDF 算法、页面与文字视图、默认图片／目录路由、中英文、浅深色和 860 宽度 |
| `bash scripts/tests/check-workflow.sh` | 旧文本完整原生工作流通过：合并、独立撤销、查找替换、复制、手动保存与恢复、清空恢复、菜单快捷键、设置、工具栏、文件夹与图片双语界面 |
| `bash scripts/tests/check-image-comparison.sh` | 569 项图片引擎检查通过：变换、四角、比例锁、翻转、裁剪、透明、预算与取消 |
| `python3 -m unittest discover -s scripts/tests -p 'test_github_release.py'` | 12 项既有发布流程检查通过 |
| 构建、签名与包内执行 | `bash scripts/build-app.sh` 和 `codesign --verify --deep --strict dist/CrossDiff.app` 通过；真实 release helper 执行包内 PDF 算法并返回预期结果 |
| 公开内容检查 | `python3 scripts/audit-publication.py --app dist/CrossDiff.app` 与 `git diff --check` 通过；当前文档链接、JSON 示例和 plist 通过检查 |

所有开发输入、临时副本、缓存、隔离会话、截图与构建产物都保存在项目目录内。未安装到其他项目或 `/Applications`，未提交或推送 Git、未创建远端发布。

## 验收中修复的问题

- PDF 页面数据与文字有效，原 PDFView 的完整父视图却未绘制正文。以同页直接绘制对照定位后，改用 PDFKit page drawing 的原生滚动视图。新增完整父视图页面正文像素断言，防止“截图有尺寸”被误判为渲染正确。
- 深色 PDF 缩放控件改为有明确主题颜色的原生菜单；文字模式隐藏页面缩放。
- 安装下载与拖入预览互斥，避免覆盖待批准的包；损坏的单个外部插件不再使健康和内置插件从列表消失。
- 进程退出后补读 stderr，避免尾部输出漏过预算；结果仍需通过 runID、协议与视图 schema 检查。
- 默认目录和图片路由优先保留原有行为；合法插件不能仅靠扩展名覆盖图片入口，名为 `.pdf` 的目录仍按目录打开。

截图位于 `.build-plugin-workflow/renders/` 和 `.build-workflow-checks/renders/`，均为虚构数据的完整原生窗口。编译时出现 prefix-map 后的 SDK module-cache 调试引用警告，未导致构建失败；分发副本已剥离调试信息，并通过签名和路径扫描。

## 实际交付与边界

- `dist/CrossDiff.app`；独立包位于 `dist/Plugins/PDF.crossdiffplugin` 与 `dist/Plugins/JSON.crossdiffplugin`，同目录附 LICENSE 与 NOTICE。
- 实验接口 v1，仅有原生页面和表格结果视图。当前工作台与附带插件只实现两方比较；三方与多对象只有输入角色和能力验证。
- PDF 是页面预览和提取文字分析；不提供 OCR、密码输入、完整分辨率视觉相等保证或 PDF 写回。每文件 48 MiB、前 200 页、文字和 384 px 页面指纹有明确预算。
- 受限 JavaScript 不是操作系统沙箱；PDFKit 的宿主解码不在 helper 内。原生完全信任代码需逐内容批准，隔离标记不被移除；本预览拒绝隔离中的原生程序。资源监测不保证限制原生程序的后代进程树。
- 未运行真实公网插件下载、Finder 手工拖入／系统文件面板、VoiceOver、实际输入法候选窗和长时间日常使用；这些仍需人工验收。下载策略已通过离线传输测试，调用安装入口已通过原生程序测试。
- 未验证 Intel 或 macOS 14 实机、Developer ID／公证分发，也未实际运行远端 CI。CI 配置新增检查不等于远端已通过。
- 本次未重新运行所有单独的编辑器、对齐、滚动与图片窗口检查；上表记录本次实际运行的相关回归，不宣称 `check-all.sh` 全套重新执行。

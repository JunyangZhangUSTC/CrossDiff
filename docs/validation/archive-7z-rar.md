# 7z／RAR 源码预览验证记录

日期：2026-10-04。分支：`zhangjy/zip`。应用：0.13.0 源码预览（build 28），Archive 插件 0.1.1。所有研发、夹具和生成物均位于 `CrossDiff-zip`。

## 实际交付

- 在现有新建、打开与归档比较流程中识别 `.7z`／`.rar`，沿用原生目录树、“按路径”与“相同内容”视图，无新增操作负担。
- 支持无密码、单卷 7z 的 Copy／LZMA／LZMA2、常见 BCJ／Delta、普通或固实压缩；支持受限非固实 RAR4 以及算法 v0 的普通／固实 RAR5。
- 可与 ZIP、TAR、其他受支持压缩包或本地目录互比。只读处理，不写出解压文件，不跟随链接，不因缺卷或解码失败发布空的“相同”结果。
- 使用系统 libarchive；7z 压缩头通过系统 liblzma 解码。未引入全局工具或下载运行时解码器。
- 新增 `CrossDiffArchiveReader`，由父进程传入已打开的只读文件描述符；预检格式与预算后完整读取、按条目核对长度／CRC、计算 SHA-256。7z 额外核验声明的压缩流 CRC 与固实组 CRC。
- 读取进程具有取消、60 秒墙钟／CPU、16 MiB 响应及采样 RSS 看门狗控制。它不是 OS 安全沙箱，RSS 采样也不保证瞬时内存峰值。

精确支持范围与预算以[使用指南](../usage.md#archives)为准。密码、分卷、自解压、RAR4 solid、RAR 7 新算法与未支持扩展均未实现；本次不创建版本标签或触发 Release 发布。

## 已执行检查

| 检查 | 结果 |
| --- | --- |
| `bash scripts/check.sh` | 核心回归全部通过 |
| `bash scripts/tests/check-archives-core.sh` | 97 项通过，含原有 ZIP／TAR 及路径、压缩流、损坏与预算规则 |
| `bash scripts/tests/check-archive-native.sh` | 118 项通过，含真实 7z／RAR、跨格式内容一致、CRC、错误类别、helper 失败及取消回收 |
| `bash scripts/tests/check-archive-plugin.sh` | 52 项通过，含每侧 10,000 条目的匹配 |
| `bash scripts/tests/check-office-import.sh` | 61 项通过，共享 ZIP 解析的 Office 导入无回归 |
| `python3 -m unittest discover -s scripts/tests -p test_plugin_inventory.py` | 7 项通过 |
| `bash scripts/tests/check-archive-workflow.sh --build-only` | 原生工作流和专用 helper 编译成功 |
| 同脚本环境运行 `archive-workflow-checks` | 实际原生窗口检查通过，包含 7z／RAR 路由、真实 helper、对比模型、损坏拒绝、旧结果保护、只读源文件及中英文／浅深色／窄窗口 |
| `bash scripts/build-app.sh` | Full 应用构建成功，产物 `dist/CrossDiff.app` |
| `bash scripts/build-app.sh --edition base --output "$PWD/.build/research-7z-rar/base/CrossDiff.app"` | Base 应用构建成功，同样带有归档读取组件 |
| `codesign --verify --deep --strict`（两版应用） | 通过；Full 内 `CrossDiffArchiveReader` 还单独验证签名 |
| 直接检查 Full 包中的读取组件 | 压缩头 7z、固实 RAR5 成功；错误 Pack／Folder／仅 Folder／文件内容 CRC 全部返回 damaged |
| `git diff --check` | 通过 |

首次原生窗口运行因执行环境无法连接 macOS 窗口服务而超时，不计为通过；该测试进程退出后，在允许窗口服务访问的环境中串行重跑相同构建，最终通过。只操作本项目的专用进程及测试数据，没有结束用户应用或操作其他分支。

原生图片位于本项目生成目录 `.build-archive-workflow/renders/`；已人工检查 `archive-paths-light.png` 与 `archive-paths-dark-narrow.png` 的文字、列、状态和底栏可见性。图片复用原有视图，未加入 README 宣传图。

## 测试与兼容边界

当前实测环境为 Apple Silicon、macOS 26.6.2，系统 libarchive 3.7.4／liblzma 5.4.3。未在 macOS 14／15 等其他系统版本或 Intel 硬件上运行；旧系统库缺少所需能力时明确失败，不回退到外部命令。

快速检查未通过真实超大负载触发 60 秒超时与 512 MiB RSS 阈值；已经验证运行中取消、进程回收、超量响应、压缩头／字典超限的提前拒绝。额外审查用独立小型合成包发现并修复了系统库忽略部分 7z CRC 的问题，正反样本已纳入持久回归。

离线夹具的来源、固定摘要、BSD 条款与重建参数见[夹具说明](../../scripts/tests/fixtures/archive-native/README.md)。没有将 7-Zip 可执行文件或系统库复制进分发应用。最终 Full 读取组件为 2,414,000 字节（约 2.30 MiB）；它和现有宿主一起使用本地 ad-hoc 签名，不是公证发布包。

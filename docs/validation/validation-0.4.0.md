# 0.4.0 开源发布准备验收

日期：2026-10-01。版本 `0.4.0`，构建号 `10`，本机验证架构 `arm64`。

## 已完成

- 默认简体中文 `README.md` 与英文 `README.en.md`：相同能力和隐私边界，双语横幅，随浅深色切换的实际窗口截图；明确列出尚未实现的 PDF、文档、表格与三方合并。
- 图标及横幅由项目内 Swift 向量绘图生成，保留 SVG/PNG 源素材和生成入口。应用 ICNS 的十种尺寸经 macOS ImageIO 独立解码验证。
- GNU 官方 AGPL v3 原文和版权说明；应用包内附 LICENSE、NOTICE。
- 贡献、安全、使用、开发、发布文档及 Issue/PR 模板；历史验收记录集中到 `docs/validation/`。
- 本轮开始时的六次历史提交及五个附注标签已统一为 `Junyang Zhang <zhangjunyang@mail.ustc.edu.cn>`；保留文件树、日期、消息和版本关系。轻量标签随目标提交更新。
- 源码、所有可达历史 blob、提交消息和标签消息的启发式扫描未发现配置规则覆盖的密码、密钥或私人路径；公开维护者邮箱保留。
- 旧应用二进制曾包含编译时开发目录。构建现在映射源路径并剥离打包副本的调试信息，重建后的应用包扫描通过。开发会话、测试数据、缓存和 Git 内部数据均不进入发布源码归档。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `bash scripts/check-all.sh` | 六组检查串行通过：核心、原生编辑器、对齐、滚动布局、删除预览和完整工作流 |
| 完整工作流中的菜单、查找与替换 | 本轮通过，包括之前 0.3.2 记录过超时的查找框撤销／重做；保留历史记录，不将一次通过表述为永不波动 |
| `bash scripts/render-readme.sh` | 八张中英文、浅深色、普通／删除预览的真实窗口渲染完成；虚构内容，无个人路径或真实文档 |
| `bash scripts/build-brand.sh` | 品牌 PNG/SVG 和十尺寸 ICNS 生成、校验通过 |
| `bash scripts/build-app.sh` | Release 构建通过，附带新图标和许可文本 |
| `codesign --verify --deep --strict dist/CrossDiff.app` | 通过 |
| `python3 scripts/audit-publication.py --history --app dist/CrossDiff.app` | 配置模式检查通过；额外显式身份检查通过 |

原始日志保存在项目内忽略目录 `.build/release-prep/`。原生程序使用独立会话，不读取用户真实文件或系统剪贴板。

发布脚本从干净提交生成应用 ZIP、同提交源码归档、构建信息和 SHA-256 校验和；拒绝隐藏索引改动，剥离 ZIP 所有者扩展元数据，解压副本后再次验证签名。具体运行产物及校验和保存在 `dist/releases/`，不提交 Git。

## 发布边界

- 尚无 GitHub remote，本轮没有推送、创建 Release 或运行远程 CI。CI 配置不等于远程执行成功。
- 当前产物为 arm64 本地 ad-hoc 开发预览，尚未完成 Intel 实测、Developer ID 签名或 Apple 公证。
- 本机敏感信息检查是启发式扫描与人工内容复核，不是全面安全审计；未做网络抓包。应用源码中未发现网络客户端、遥测或账号流程。
- 会话数据以本地明文 JSON 保存；不会上传，但不声称加密或安全擦除。系统同步目录、备份和其他本机进程属于应用之外的边界。
- 真实输入法候选窗、Finder 拖放、VoiceOver 与长时间日常使用仍需人工验收。

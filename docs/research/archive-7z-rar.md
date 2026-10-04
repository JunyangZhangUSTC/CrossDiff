# 7z / RAR 比较：引擎能力、接入代价与验证边界

调研日期：2026-10-04。工作目录：`CrossDiff-zip`，分支：`zhangjy/zip`。本文保留选型阶段的调研与样例数据。后续已在本分支实现系统库支持的保守子集，实际能力以[使用指南](../usage.md#archives)为准；密码与分卷仍不支持。原 ZIP/TAR 保证见 [archive-comparison.md](archive-comparison.md)。

## 判断

增加“常见、无密码、单卷 7z”是可沿现有目录快照接入的中等改动；承诺日常意义上的“7z / RAR 支持”，包括 RAR4 solid、密码、加密文件名、分卷和新版 RAR，则是较大的原生读取能力扩展。真正的成本是解码边界、资源控制、取消、完整性和兼容性验收，不是给扩展名列表增加两项。这里的大小是工程相对估计，不是排期承诺。

**若近期只补保守子集，先评估系统 libarchive；若目标包含常见加密与 solid RAR，优先验证受控的 7-Zip helper。自带最新版 libarchive 能固定版本，却不会补齐它尚未实现的解密与 RAR4 solid。** Apple 原生压缩框架不是 7z/RAR 归档读取器的直接替代品。以下分开记录上游源码事实、工程推断与尚未实测的事项。

## 当前项目的接入位置

原生宿主 [ArchiveCatalog.swift](../../Sources/CrossDiffCore/ArchiveCatalog.swift) / [ArchiveStream.swift](../../Sources/CrossDiffCore/ArchiveStream.swift) 负责读取与 SHA 快照；[内置 JS 插件](../../Plugins/Official/Archive/compare.js) 负责目录匹配。因此主要改动在宿主，仅下发新的 `.crossdiffplugin` 不够。目录树 UI、摘要和匹配协议可以复用；[插件 manifest](../../Plugins/Official/Archive/manifest.json) 与 [ArchiveComparisonModel.swift](../../Sources/CrossDiff/ArchiveComparisonModel.swift) 的格式路由需同步。[OfficeImport.swift](../../Sources/CrossDiffCore/OfficeImport.swift) 共用 ZIP 读取路径，改读取抽象时需验证办公导入回归。

当前预算为源归档 ≤2 GiB、展开内容合计 ≤512 MiB、单文件 ≤256 MiB、最终目录项 ≤10,000。增加格式不会自动扩大这些预算，不能承诺任意多 GB 的 RAR 大包；solid、字典与压缩头还需要各自的内部预算。相关现有约束见 [压缩包实现研究](archive-comparison.md)。

## 本次固定的上游版本

| 项目 | 核查基线 | 证据与说明 |
| --- | --- | --- |
| libarchive | **3.8.9，2026-07-28** | 调研时官网稳定版；源码引用固定 `v3.8.9`，不将 `master` 能力当成已发布能力。[官网](https://www.libarchive.org/)、[发布记录](https://github.com/libarchive/libarchive/releases/tag/v3.8.9) |
| 7-Zip | **26.03，2026-09-03** | 官网提供 macOS arm64/x86-64 console 包，适合评估 `7zz` helper；不是依赖用户安装 Homebrew，也不是独立维护的 p7zip 16.02。[下载页](https://www.7-zip.org/download.html)、[26.03 源码说明](https://github.com/ip7z/7zip/blob/26.03/DOC/readme.txt) |
| RAR 格式 | RARLAB 当前 RAR5 格式规范，2026-10-04 查阅 | 名为 RAR5 的容器已有 compression algorithm version 0 与 1；version 1 要求 RAR 7.0+ 解码能力，不能把“RAR5”视作永远不变的单一 codec。[格式规范](https://www.rarlab.com/technote.htm) |

系统 libarchive 的实际版本与编译选项随 macOS 环境而变。本文对 3.8.9 的源码核查不能替代所有目标系统的运行时验证，也不能用“format 注册成功”证明包内每个文件可正确解码。

## 本机实验与体积实测

环境为 **macOS 26.6.2、系统 libarchive 3.7.4**；`7zip/rar/rar5` 三个 reader 注册均返回成功。从 v3.8.9 上游测试集挑选 23 个正例与预期失败样例，每次通过 `archive_read_open_filename` 仅提供一个样例文件，消费内容、核对声明/实际长度并计算 SHA-256：14 个完成读取与长度检查、8 个由库报错、1 个被探针的额外长度检查拒绝。**14/23 不是兼容率**。探针不等同于产品持有 fd 的安全读取路径。`.build/research-7z-rar/probe.py` 与 `system-probe-results.json` 位于该项目研究目录，仅本机保留，不作为已提交的产品测试套件。

| 本机样例 | 观察结果 |
| --- | --- |
| 7z LZMA1/LZMA2/BZip2/Deflate/PPMd/BCJ+LZMA2/ARM64+LZMA2 | 7 个样例完成读取；Zstd 和 solid Zstd 两个样例明确不支持。 |
| 普通 RAR、normal/best 压缩 RAR | 3 个样例完成读取；RAR5 stored/compressed/solid/multiple-files-solid 4 个也完成读取。 |
| 加密 | 7z 内容/头加密 2 个失败；RAR4/5 内容/文件名加密 4 个失败。部分系统库错误表现为格式/压缩错误，不能依赖单一英文错误文本识别密码问题。 |
| RAR5 只提供分卷首卷 | 一个样例声明条目 144,608 字节却读到 0 字节，探针的长度核对阻止其成为成功结果；这是此调用方式与此样例的观察，不是所有缺卷的普遍行为。 |
| 新生成的 7z | 3 个源文件、1 MiB 字典，分别生成普通 solid、AES 内容加密、AES 头加密和 4 KiB 分卷。7zz 26.03 的 `t` 均成功；系统探针仅普通 solid 成功，三个文件均逐个核对源 SHA-256，两种加密明确不支持，分卷不在单来源探针范围。结果仅本机保留于 `.build/research-7z-rar/generated-results.json`。 |

官方 macOS 26.03 下载包 **1,863,192 字节**，SHA-256 为 `5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480`。其中通用 `7zz` 为 **6,069,184 字节**；`lipo` 仅保留 arm64 后为 **2,988,992 字节**。只将该 binary 用 DEFLATE level 9 压成 ZIP，通用/arm64 分别为 **2,602,466 / 1,271,821 字节**。这说明 helper 本身是数 MiB 量级，**不是最终 `.app` 或发布 ZIP 的增量**：还需计算许可证、签名、其他资源及最终打包方式。[官方固定资产](https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz)

这些实验未测速度或内存峰值，未覆盖其他 macOS，也未证明产品管线已经接入；RAR4 solid、完整 RAR 分卷和 RAR7 算法仍以源码证据及后续验收为界。

## 固定版 libarchive 的能力边界

下表描述上游 3.8.9 的读取实现；是否成为 CrossDiff 的产品支持，仍取决于白名单、预检与回归样例。

| 输入 | 源码能够证明的能力 | 不能据此承诺的能力 |
| --- | --- | --- |
| 无加密 7z | 有 Copy、LZMA/LZMA2、PPMd、BZip2、Deflate、Zstd 等实现分支，以及若干 BCJ/Delta 过滤组合；LZMA、BZip2、Zstd、zlib 等受编译依赖影响。支持按 folder/substream 解码常见 solid 结构。 | 7z 是可扩展 coder graph，多个 coder/过滤器组合仍可能被拒绝；BCJ2 仅支持部分布局。ARM64/RISC-V 过滤能力也涉及 liblzma 版本/编译选项。不能宣称任意 `.7z`。[7z reader](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_7zip.c)、[上游读取测试](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_7zip.c) |
| 7z 内容加密／头加密 | 能识别加密 coder，标记加密状态。 | `setup_decode_folder` 对内容加密返回失败，对加密头返回致命错误；添加 passphrase 回调不会凭空补上 decoder。[加密分支](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_7zip.c#L3840) |
| RAR4／旧 RAR reader | 可读部分普通、非 solid、无加密归档，有分卷处理分支。 | 遇 `FHD_SOLID` 明确报 `RAR solid archive support unavailable`；内容与头加密均无解密实现。内容加密时可能仍能列出条目；这不是解码成功。[RAR reader](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_rar.c#L1409) |
| RAR5 | 有普通、solid 和分卷读取；上游有 solid 分卷全量解码测试。 | 内容与头加密均明确不支持；当前 reader 的字典硬上限是 **64 MiB**。成功读某个 RAR5 样例不能推导新版 RAR 的全部支持。[RAR5 reader](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_rar5.c)、[RAR5 测试](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_rar5.c#L443) |
| 分卷 | RAR reader 含卷间状态机；`archive_read_open_filenames` 可接受调用者提供的多个来源。 | 不等于替 CrossDiff 自动且安全地发现、排序、授权、锁定所有 sibling 文件。`.7z.001` 等字节分割还须提供正确的拼接／可寻址输入；本次未完成该组合验证。[多文件输入实现](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_open_filename.c#L117) |

**新版 RAR 的特别边界。** RARLAB 规范用 5 位表示基础字典尺寸，并为算法版本 1 增加非 2 的幂次字典和其他位。libarchive 3.8.9 的 `process_head_file` 仍按 4 位解析字典、限制至 64 MiB；它把算法版本保存为 `cstate.version`，该文件中没有据此选择新版解码算法的分支。因此应把算法版本 1／未知位明确纳入预检拒绝或专门验证，不能假设库会完整识别后才安全拒绝。[RARLAB compression information](https://www.rarlab.com/technote.htm)、[固定版解析代码](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_rar5.c#L1823)

## 四种实现路线

| 路线 | 新增依赖与交付 | 能力收益 | 工程代价判断 |
| --- | --- | --- | --- |
| 继续系统 libarchive | 不随应用增加一份归档引擎；保留运行时符号探测。 | 最适合无加密、单卷、明确 codec 白名单的第一阶段。 | **中等**：要增加格式专属预检、错误分类和测试；支持 macOS 版本越多，行为差异验收越多。库修复节奏受系统更新约束。 |
| 固定版本自带 libarchive | 自建/固定库和依赖，选择静态或动态链接，纳入构建、签名、NOTICE 与安全更新。 | 可以统一 reader 版本和编译能力，回移补丁。 | **中等偏高**：多一套依赖维护；上述加密、RAR4 solid、新 RAR 边界依然存在。单为“支持更多格式”换库不一定划算。 |
| 固定 7-Zip macOS helper | 官方 `7zz` 或基于 26.03 源码的精简 helper；应用随包交付并校验版本。 | 同一个引擎覆盖常见 7z、RAR4/RAR5、solid、密码/头加密、分卷和 RAR7 算法。 | **较高但覆盖直接**：进程协议、无落盘读取、密码通道、取消、资源隔离、签名与混合许可证；不是调用 `l` 列表就完成。 |
| LZMA SDK + UnRAR | 至少两套解码实现/适配、两种许可和更新源。 | LZMA SDK 可提供小范围的 7z 解码；UnRAR 面向 RAR 本身。 | **较高**：接口和能力不统一，SDK 精简 decoder 并不覆盖全部 7z；适合有明确代码体积/许可分层目标后再选。 |

以上是架构推断。未构建自带 libarchive 或定制 helper，不填写它们的最终 `.app` 大小、速度、内存峰值或开发工期。正式估算需要固定功能范围，再用目标构建方式和代表样例测量。

### 7-Zip helper 的实际范围

7-Zip 24.01 的历史记录已经加入读取 WinRAR 7.00 大字典归档，24.03 又加入 RAR 解码的内存额度选项。26.03 的 `Rar5Handler.cpp` 明确处理算法版本 0/1、头与内容密码回调、solid 及多卷回调；未知算法版本仍会拒绝。这是选择它研究广覆盖路线的依据，不是“以后任何 RAR 都能读”的保证。[版本历史](https://www.7-zip.org/history.txt)、[26.03 RAR5 handler](https://github.com/ip7z/7zip/blob/26.03/CPP/7zip/Archive/Rar/Rar5Handler.cpp)

`7zz`、`7za`、`7zr` 不能互换。官方源码说明中，`Alone2/7zz` 对应全部格式，`7za` 与 `7zr` 是缩减版；`DISABLE_RAR_COMPRESS=1` 会去掉受额外许可限制的 RAR 解码器，但仍可能列出 RAR 目录或读 stored 项。**能列出 RAR 文件名并不能证明所交付 binary 带有 RAR 解码器。** 固定包后应检查 `7zz i` 和实际压缩 RAR 样例。[26.03 构建说明](https://github.com/ip7z/7zip/blob/26.03/DOC/readme.txt)

官方 `-so` 将内容写到 stdout；`-slt` 是列表技术信息，并非为 CrossDiff 定义的逐条目带长度消息协议；返回码 1 是 warning，不能当成全量比较成功。依据为 [26.03 官方 macOS 包](https://github.com/ip7z/7zip/releases/download/26.03/7z2603-mac.tar.xz) 随附的 `Manual/cmdline/switches/stdout.htm`、`list_tech.htm` 与 `Manual/cmdline/exit_codes.htm`（本次已读取）。

工程建议是先做一次顺序扫描、为每个条目计算摘要并返回显式的类型/长度/完成状态。若只是“列目后每个文件启动一次 `7zz x -so`”，solid 包可能反复解码前序数据；若把全部输出按未验证的头部尺寸直接切分，则混入大小未知、损坏、重复路径等问题。可选的定制 helper 应使用引擎的条目回调与输出流，维护一个受控协议；它自身也必须校验请求与响应，并在整包成功结束前不发布完整快照。这里是设计建议，尚未完成原型。

### LZMA SDK 不是完整 7-Zip 引擎

26.03 的 ANSI C 7z decoder 主方法白名单为 Copy、LZMA、LZMA2，以及启用编译选项时的 PPMd；有多种分支转换器/Delta，但 coder graph 仍受限制。该实现没有 AES coder 或密码 API，不能据此提供加密 7z。SDK 中的单独 LZMA codec 与完整 7z 容器也要分清。[C decoder](https://github.com/ip7z/7zip/blob/26.03/C/7zDec.c)、[C API](https://github.com/ip7z/7zip/blob/26.03/C/7z.h)、[编译选项](https://github.com/ip7z/7zip/blob/26.03/C/Util/7z/makefile.gcc)

`SzArEx_Extract` 按 folder 的整个未压缩大小分配输出缓存；solid folder 中多个文件可复用此缓存，但这不是按成员逐块输出的内存模型。不能将“小 decoder 源码”推导为“大 solid 包也只占小内存”。随源码的 `DOC/7zC.txt` 标题仍是 9.35，方法说明比当前源码窄，能力判断应以固定版本实际实现为准。[分配与解码代码](https://github.com/ip7z/7zip/blob/26.03/C/7zArcIn.c#L1632)、[历史说明](https://github.com/ip7z/7zip/blob/26.03/DOC/7zC.txt)

## 不能丢失的比较语义

这些是接入任一引擎都要完成的工程工作，而不是某个库自动替应用完成的保证：

1. **完整读取和校验。** 对每个普通文件消费全部内容并计算 CrossDiff 的摘要；目录列举成功、归档头中的 CRC 相同和读取部分文件均不能标记整包完成。RAR5 的 libarchive 常规 skip 路径甚至特意不计算被跳过文件的校验，因此必须区别 `next_header/skip` 与实际 drain。[校验实现](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_rar5.c#L4156)
2. **格式自己的资源预算。** 现有 TAR.XZ 预检不适用于 7z 内部 LZMA/LZMA2。7z reader 使用 `lzma_raw_decoder`，BCJ2 还会按子流未压缩尺寸分配缓冲；限定应用每次取 64 KiB 不能限制 decoder 内部内存。应分别限制字典、coder 数、压缩头、solid block、条目数、实际输出、CPU/墙钟时间，并验证取消时机。[初始化代码](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_7zip.c#L1368)、[BCJ2 缓冲](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/archive_read_support_format_7zip.c#L3991)
3. **密码生命周期。** 内容加密与头加密分开呈现；密码错误、损坏和不支持算法分开处理。密码仅经专用内存/IPC 通道传给 decoder，避免拼进命令行、日志、持久化会话或错误详情；交互、重试、取消均需中英文支持。
4. **分卷来源。** 明确用户选了哪组卷；限定在授权范围内定位剩余卷，拒绝缺卷、重卷、错卷、跨目录逃逸；对每一卷记录并复核来源身份。只记录首卷的大小与时间戳不能发现后续卷变化。
5. **保留只读目录语义。** 延续危险路径、规范化后重名、链接/特殊项和尺寸预算策略。内容比较不必先写出解压文件；helper 也不应有任意目录写入能力。独立进程利于终止卡住的 decoder，但“起了子进程”本身不是 OS 沙箱或硬内存上限。
6. **保留可靠的失败状态。** 不支持的 codec、解码 warning、CRC/hash 错误、尾部/缺卷问题、超时和用户取消均不得悄悄降级成相同内容或完整快照。上游错误文本不是稳定的产品错误枚举，应在适配层映射。

上游截至调研日还有 [7z BCJ2 无界分配报告 #3464](https://github.com/libarchive/libarchive/issues/3464)。本次检查源码中的分配策略，但没有复现该报告的攻击样例；它应进入升级/回归清单，不能写成已在 CrossDiff 中确认的漏洞，也不能认为升级至“最新版”就无需资源约束。

## 许可证与 Apple 原生框架

本节只整理实际发行文件/官方文档中的条款和技术范围，不用“免费”“开源”替代再分发判断。

| 组件 | 固定版本许可与再分发边界 |
| --- | --- |
| libarchive 3.8.9 | 主体 BSD 2 条款；保留版权、条件和免责声明。少数文件另有 BSD 3 条款、公有领域或多选许可，依赖也各有许可。不能一律称作 MIT 或无义务的系统代码。[COPYING](https://github.com/libarchive/libarchive/blob/v3.8.9/COPYING) |
| 7-Zip 26.03 / macOS 7zz | 主体 LGPL 2.1-or-later，部分 BSD 2/3 条款，RAR decoder 另有 unRAR restriction；不是纯 BSD/MIT，也不是简单的 GPL。应随 binary 保留对应版权/许可文本并履行适用源码义务。[固定 License](https://github.com/ip7z/7zip/blob/26.03/DOC/License.txt)、[官方 FAQ](https://www.7-zip.org/faq.html) |
| LZMA SDK 26.03 | 官方 SDK 原始代码为公有领域，可商业使用、修改和分发；不能把它的许可套到完整 7zz 或 UnRAR。[SDK 页面](https://www.7-zip.org/sdk.html) |
| UnRAR | RARLAB 官网当前源码包 `unrarsrc-7.3.1` 的内部版本是 **7.30 beta 1，2026-09-09**，并非稳定版推荐。允许用于处理 RAR，禁止据源码重建专有压缩算法/开发兼容压缩器；修改源码分发有保留限制说明的要求。此包已允许随其他软件包分发，不应套用网上旧版的分发收费条文；固定版本时重新读取其 `license.txt`。[官方入口](https://www.rarlab.com/rar_add.htm)、[本次核查源码包](https://www.rarlab.com/rar/unrarsrc-7.3.1.tar.gz) |

CrossDiff 当前是 AGPL-3.0-only。选择独立 helper 不会取消该 helper 自身的 LGPL/BSD/unRAR 再分发义务，也不能仅凭“进程隔离”就宣布整体许可兼容。交付前要确定实际组合方式，随包保存精确版本条款、变更和构建资料，以及适用的对应源码获取/提供方式；不能只放一个泛指上游首页的链接就默认满足所有条件。LGPL §4、§6 分别涉及 binary/对应源码和组合使用条件；GNU FAQ 也说明程序边界需要结合通信语义判断，应对照实际方案核对。[LGPL 2.1 原文](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt)、[GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)、[项目许可](../../LICENSE)

Apple `Compression` 的 `COMPRESSION_LZMA` 文档限定为 **XZ 容器中的 LZMA2**，不是 7z 容器、coder graph 或 RAR decoder。`AppleArchive` 面向 Apple 的压缩/归档与加密归档 API，公开接口没有承诺通用 7z/RAR 读取。因此这两者不能直接替代上述归档引擎；已有系统 libarchive 则属于另一套库。[Compression 文档](https://developer.apple.com/documentation/compression/compression_lzma)、[AppleArchive](https://developer.apple.com/documentation/applearchive)、[WWDC21 介绍](https://developer.apple.com/videos/play/wwdc2021/10233/)

## 建议的分期与验收

**第一阶段：无加密、单卷、明确方法的 7z。** 优先证明能复用现有目录与摘要流程；把不在白名单内的 codec/过滤链、超大字典和压缩头明确拒绝。若为最小依赖选择系统 libarchive，应为每个最低支持 macOS 保留固定样例结果。RAR 可另列保守子集，界面文案不能只写无条件“支持 RAR”。

**第二阶段：用受控 helper 扩展常见 RAR 和密码。** 先证明一次顺序扫描可完整产生每条目的摘要、类型与校验结果，再接入密码交互和终止机制；许可、binary 固定与签名跟实现同时收口。若目标一开始就必须兼容网上常见的 solid/加密 RAR，可直接从这一阶段做原型，避免先投入另一套只能覆盖少量 RAR 的适配。

**第三阶段：分卷及进一步 codec 覆盖。** 先建立多来源身份与一致性模型，再开放分卷入口；大字典只在明确预算内开放。SFX、恢复卷修复、任意未知 coder、密码持久化等需另设范围，不应自然包含在“读取 RAR”里。

最低验收矩阵：

| 维度 | 代表性样例与必须观察的结果 |
| --- | --- |
| 7z | Copy、LZMA、LZMA2、PPMd；solid/non-solid；压缩头；BCJ/BCJ2/ARM64/RISC-V 的允许与拒绝组合；未知 codec；空包、目录、Unicode/emoji、重复路径。 |
| RAR | RAR4 普通与 solid；RAR5 算法 0 普通与 solid；算法 1/大字典明确支持或明确拒绝；stored 与真实压缩项分别验证。 |
| 密码 | 正确/错误/空密码，内容加密、文件名加密，两侧不同密码，取消输入，密码不进入日志或会话。 |
| 分卷 | 完整、缺失、乱序、重复、首卷之外变更；卷边界跨越一个文件或 solid 流；可预期的总预算与取消。 |
| 完整性 | 修改头/数据/CRC、截断、尾垃圾；声明长度与实际输出不符；decoder warning、延迟到末尾的错误不能发布成功快照。 |
| 资源与宿主 | 小文件配超大字典、巨大压缩头、巨大 solid block、超多条目、慢流/卡住、并发比较、取消后子进程与缓冲释放；现有 ZIP/TAR 与 Office 共用读取路径回归。 |
| 交付 | 目标 macOS 和架构、固定依赖 hash、许可证/NOTICE/源码履约材料、嵌入 helper 签名及打包后可运行；全量归档性能以实际数据测量。 |

当前没有产品功能实现，也没有对固定 libarchive 自建包、定制 helper、密码 UI 或分卷来源模型作完成验收。成功的单一引擎样例只能证明该样例，不能替代上述矩阵。

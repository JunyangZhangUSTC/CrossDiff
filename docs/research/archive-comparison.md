# 压缩包虚拟目录：系统读取器与完整性边界

调研与本机验证日期：2026-10-01。本文记录 0.7.0 的实现依据和保守子集，不是“所有 ZIP/TAR 都可读取”的承诺。产品用法见 [usage](../usage.md#archives)，入口见 [ArchiveCatalog.swift](../../Sources/CrossDiffCore/ArchiveCatalog.swift)。

## 结论

本次采用系统 libarchive 的动态 C ABI 桥接，流式读取 ZIP 和 TAR 压缩流，不提取文件到磁盘，不调用外部解压程序。文件 SHA-256 及规范化相对路径构成目录快照；路径分类和跨路径相同内容分组交给独立执行的内置 JavaScript 插件。符号链接、硬链接和特殊文件保留为未验证项，不跟随目标。以上是当前实现选择，不是 libarchive 默认提供的安全策略。

## 系统库与接口证据

本机实际检查的 SDK 是 `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`。其 include 目录没有 `archive.h` / `archive_entry.h`，但 `usr/lib/libarchive.2.tbd` 声明了所需符号，SDK 的 `archive_read_open.3`、`archive_read_data.3`、`archive_entry_stat.3` 给出了 C 原型。不能把“读过本机 man page 与符号表”写成“本机 SDK 含这些头文件”。

本机通过 `/usr/lib/libarchive.2.dylib` 的 `dlopen` / `dlsym` 调用 `archive_version_string`，返回 **libarchive 3.7.4**；none/gzip/bzip2/xz 过滤器与 seekable ZIP/raw 格式注册都返回 `ARCHIVE_OK`。此结果只代表本机环境，运行时仍逐项检查符号与注册结果。libarchive 使用不透明对象，官方示例提供 allocate/register/open/header/data/free 生命周期，适合用明确的 `@convention(c)` 类型桥接，无须自建 C 模块或安装依赖。[libarchive 官方示例](https://github.com/libarchive/libarchive/wiki/Examples)

`archive_read_open_fd` 不负责关闭调用者传入的 fd；`archive_read_data` 接收调用者的缓冲区，返回实际字节数，0 表示当前条目 EOF，负数表示错误。`next_header` 可自动跳过未读内容，因此“成功列出名称”不能证明内容已验证。实现持有普通文件 fd，每次最多请求 64 KiB 输出，并完整读取条目；不使用可能返回较大内部块的 `read_data_block`，也不调用提取 API。[公开 API](https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h)、[读取实现](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read.c)、SDK 上述 man pages

ZIP 使用 seekable reader，先独立检查中央目录及每个本地 header。seekable 与 streamable ZIP 的处理范围不同，不应默认用流式列表证明中央目录完整性。ZIP CRC mismatch 可能通过警告返回；本实现只接受成功状态，并对读出的内容独立计算 CRC32，与中央目录比较。[ZIP reader 源码](https://github.com/libarchive/libarchive/blob/master/libarchive/archive_read_support_format_zip.c)

## 两个不能依赖默认行为的地方

**gzip 尾校验。** 本机对正常 gzip、尾 CRC 翻转一位、ISIZE 翻转一位三个样例进行直接调用：libarchive 3.7.4 均正常返回解码内容和 EOF。上游 gzip filter 也保留了校验 trailer 的 TODO。因此仅 drain 到 EOF 不足以授予可信内容状态。[gzip filter 源码](https://fuchsia.googlesource.com/third_party/libarchive/+/refs/heads/upstream/master/libarchive/archive_read_support_filter_gzip.c)

当前 [ArchiveGZIP.swift](../../Sources/CrossDiffCore/ArchiveGZIP.swift) 先通过系统 `/usr/lib/libz.1.dylib` 的 `gzdopen` / `gzread` / `gzerror` / `gzclose` 做有界完整性验证，再执行 TAR 读取。传入 dup 后的 fd，由 gzclose 关闭；逐块检查错误，不能只检查 `gzread == 0`，因为截断可通过 `Z_BUF_ERROR` 延迟报告。zlib 支持拼接 gzip 成员，所有成员都要通过校验。[zlib 官方手册](https://zlib.net/manual.html)、本机 SDK `usr/include/zlib.h`

zlib 和 libarchive 可能忽略压缩流后的非成员垃圾。因此 TAR 读取除了消耗解码后的零填充，还核对 `archive_filter_bytes(handle, -1)` 与源文件大小相等。本机 probe 中正常 gzip 为 46/46 字节，追加 1 或 400 字节后仍只消耗 46 字节；这些尾部在实际目录 API 回归中被拒绝。这是当前系统 ABI 的实测证据，仍需在其他支持的 macOS 版本持续回归。

**XZ 内存。** 上游 libarchive xz filter 对现代 liblzma 传入 `UINT64_MAX` 内存限额，reader 层未暴露相应配置；限制流式输出大小不能阻止预先分配巨大字典。liblzma 自身的 decoder API 有 memlimit，但本次没有自行复制其状态结构 ABI。[xz filter 源码](https://fuchsia.googlesource.com/third_party/libarchive/+/refs/heads/upstream/master/libarchive/archive_read_support_filter_xz.c)、[liblzma decoder API](https://tukaani.org/xz/liblzma-api/container_8h.html)

当前 [ArchiveXZ.swift](../../Sources/CrossDiffCore/ArchiveXZ.swift) 在创建 decoder 前预检严格子集：单 stream、每块仅一个 LZMA2 filter、字典最多 64 MiB，并验证全部 block/header/index 布局及实际 LZMA2 chunk 边界。不能只信 Index 的 unpadded size 跳到下一个声明的 block：伪造尺寸可以把 decoder 实际会遇到的第二个 block 隐藏在第一个范围内。数据校验仍由 liblzma 完成，预检不代替解码校验。[XZ 格式规范 1.2.1](https://tukaani.org/xz/xz-file-format.txt)、[LZMA2 decoder 源码](https://github.com/tukaani-project/xz/blob/master/src/liblzma/lzma/lzma2_decoder.c)

过滤器自动探测还可能递归解码 `gzip(xz(TAR))`。本机自动模式确实建立了 xz+gzip 链。当前按最外层 magic 选择一个过滤器，并使用 `archive_read_append_filter` 禁用后续自动探测，包括 NONE 分支；否则内层 XZ 会绕过预检。所有注册和 append 调用必须返回 `ARCHIVE_OK`，不接受可能启用外部程序的 WARN。[append-filter 实现](https://fuchsia.googlesource.com/third_party/libarchive/+/refs/tags/v3.1.900a/libarchive/archive_read_append_filter.c)

## 当前接受的格式与限制

| 范围 | 当前实现 |
| --- | --- |
| ZIP | ZIP32、stored/deflate，完整中央目录、本地名称/方法/flag/CRC/尺寸核对；支持常规 data descriptor、UTF-8 名称和符号链接未验证项。拒绝 ZIP64、多卷、加密、SFX/隐藏记录/记录间空洞、非 UTF-8 名称、Unicode path override extra field、其他压缩方法。 |
| TAR | V7/USTAR、受限 PAX、GNU long name；头 checksum、长度、padding 和末尾完整性校验。拒绝 sparse、多卷/dumpdir 扩展、危险路径及不支持的内容变换元数据。PAX/GNU 单个扩展体最多 64 KiB。 |
| gzip/bzip2 | 单层压缩的 TAR；读取到解压流末尾，拒绝未消费的源尾部。gzip 另外经 zlib 校验 CRC/ISIZE，允许可完整验证的拼接成员。 |
| xz | 单 stream，LZMA2 单 filter，字典 ≤64 MiB；只接受 CRC32/CRC64/SHA256，拒绝无校验、BCJ/Delta、拼接 stream 和 stream padding。Index ≤1 MiB、blocks ≤10,000、LZMA2 chunks ≤100,000。 |
| 路径 | ≤4,096 UTF-8 字节、深度 ≤128；去除 `.` 分量，拒绝 `..`、绝对路径、Windows drive/backslash、NUL、无效 UTF-8、规范化后重复和文件作为祖先。根 `./` 仅可作为目录忽略。 |
| 总量 | 最终 ≤10,000 项，包含合成的祖先目录；每个文件 ≤256 MiB，内容合计 ≤512 MiB，源归档 ≤2 GiB。TAR 整个解压流额外限制为 544 MiB，给 header/metadata/padding 留至多 32 MiB 余量。不是每种数据各自都能用满限额。 |

路径原始 Unicode 不主动改写，按大小写区分。Swift `String` 相等关系会把 Unicode canonical-equivalent 名称视作相同，当前选择保守拒绝碰撞；不声称能同时保留所有字节不同但规范等价的名字。隐式祖先目录补齐后，归档省略目录记录与本地目录具有一致的比较结构。显式空目录仍保留。

上述支持子集、预算和失败策略都是应用选择。任何条目解析、内容校验、完整枚举或限额失败都抛错，不返回“部分成功”的快照。成功快照中的 `isComplete` 表示全部项可验证；含链接时可成功列出完整目录，但该值为 false。目录项本身可验证，最终目录差异由插件聚合子项状态。

## 文件访问与保证范围

普通文件以 `O_NOFOLLOW` 打开并由 fstat 确认类型；文件夹用目录 fd、`openat`、`fstatat(..., AT_SYMLINK_NOFOLLOW)` 锚定逐层访问。FIFO 等特殊来源不会被当成阻塞的普通输入。目录枚举阶段就累计全局发现项数，避免深层目录的未处理名字数组绕过 10,000 项内存预算。这些是当前 [ArchiveSource.swift](../../Sources/CrossDiffCore/ArchiveSource.swift) 的实现约束。

快照记录归档源或每个枚举过的目录/文件/链接的 device、inode、mode、size、mtime、ctime；读取前后、发布前及复用缓存前复查。普通替换、截断、子文件变化或增删项会使快照失效。元数据复查不是跨两个来源的原子快照，也不保证发现可隐藏元数据变化的对抗性修改。

不提取文件、不注册 mtree/其他格式、不调用外部程序，减少了不必要的宿主访问范围，但它不是 OS 沙箱。应用输出缓冲和所列结构有界；系统库内部开销、执行时间、剩余解析器缺陷仍不能被表述成硬内存/CPU 安全隔离。64 MiB 是 XZ 字典上限，不是整个进程 RSS 上限。

## 可复现验证

运行 `bash scripts/tests/check-archives-core.sh`。脚本在项目内生成测试数据与独立构建缓存，不依赖系统安装的 Python 第三方包，不打开原生窗口、不写用户会话、不提取归档内容。

公开 API 检查覆盖固定 SHA-256 向量、空文件/空包、所有承诺的压缩格式、中文/emoji、PAX/GNU、隐式/显式目录、ZIP descriptor、源与条目限额、链接/特殊类型、非法路径/冲突、CRC/截断/加密、XZ 多块及绕过样例、嵌套压缩、压缩流尾垃圾、来源变更和取消。另一次独立 preflight probe 对五个正常 XZ 和七个恶意样例直接调用预检，不构造 decoder，证明第二块超大字典与伪 Index 在解码前被拒绝；这补充公开 API “最终失败”无法单独证明的时序证据。

原生交互、插件发布前复核与最终应用构建由集成验证覆盖，不能用本文件的 Core 检查代替。

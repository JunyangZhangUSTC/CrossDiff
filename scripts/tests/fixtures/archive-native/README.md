# 原生 7z / RAR 离线验收夹具

这些小型夹具只用于 `bash scripts/tests/check-archive-native.sh` 与原生工作流验收，不会打包到应用。普通检查只依赖项目现有 Swift/Clang、Python 标准库以及 macOS 的归档库；不联网、不下载解码器、不调用 7-Zip、不把归档内容解压到磁盘。`generate.py` 用独立已知数据生成对照目录、ZIP/TAR 和损坏变体；真实 7z/RAR 输入保存在 `archives/`。每次检查先核验 [SHA256SUMS.json](SHA256SUMS.json)。

## 自有 7z 样本

`copy.7z`、`lzma1.7z`、`lzma2.7z`、`solid.7z`、`header-compressed.7z`、`bcj.7z`、`delta.7z` 由官方 **7-Zip 26.03 macOS arm64** 从 `generate.py` 中公开、固定的字节生成。输入包含中文、emoji、空文件、显式空目录、重复文本和小型二进制内容。所有正常样本应与独立生成的本地目录逐路径、逐大小、逐 SHA-256 相等。

`encrypted-data.7z`、`encrypted-header.7z`、`split.7z.001`、`unsupported-bzip2.7z` 也由同一版本生成，分别验证拒绝数据/文件头加密、分卷和支持范围外算法；固定测试口令为 `fixture-only`，不含秘密。只保留分卷首卷。7-Zip 是夹具维护工具，未作为产品依赖，也未在此目录分发其可执行文件或源码。官方工具来源：[7-Zip 下载](https://www.7-zip.org/download.html)。

`generate.py` 记录全部编码参数；关闭时间戳记录、单线程编码。`bad-*` 变体只在检查构建目录生成：截断、额外尾部、篡改内容 CRC、LZMA2 数据/文件头 96 MiB 字典以及超过 1 MiB 的压缩/展开文件头声明。合成的资源限制输入仅含小型元数据或约 1 MiB 的字节，不实际申请广告中的大字典。

另有 Python 直接构造的六个极小 Copy 流校验样本（内容固定为 `abcdef`），用于检查 Main PackInfo CRC、solid Folder CRC 和逐子流 CRC 的组合：三组正确输入必须成功，三组仅其中一层 CRC 错误的输入必须报损坏，即使文件自己的 CRC 正确，也不能忽略容器声明的其他校验。

## libarchive 上游 RAR 样本

所有 `test_read_format_*.rar` 都是 **libarchive v3.8.9** 对应 `.uu` 文件逐字节解码的未修改副本。来源目录为 [libarchive v3.8.9 / libarchive/test](https://github.com/libarchive/libarchive/tree/v3.8.9/libarchive/test)。仅选取以下 10 个普通功能和拒绝输入，没有复制漏洞语料库：

| 样本 | 目的 | 上游测试与许可证来源 |
| --- | --- | --- |
| `test_read_format_rar.rar` | RAR4 存储、目录、符号链接 | `test_read_format_rar.c` |
| `test_read_format_rar_compress_normal.rar` | RAR4 普通压缩、符号链接 | `test_read_format_rar.c` |
| `test_read_format_rar5_stored.rar` | RAR5 存储 | `test_read_format_rar5.c` |
| `test_read_format_rar5_compressed.rar` | RAR5 压缩 | `test_read_format_rar5.c` |
| `test_read_format_rar5_multiple_files_solid.rar` | RAR5 四文件 solid | `test_read_format_rar5.c` |
| `test_read_format_rar4_encrypted.rar` | 拒绝 RAR4 数据加密 | `test_read_format_rar_encryption.c` |
| `test_read_format_rar4_encrypted_filenames.rar` | 拒绝 RAR4 文件头加密 | `test_read_format_rar_encryption.c` |
| `test_read_format_rar5_encrypted_filenames.rar` | 拒绝 RAR5 文件头加密 | `test_read_format_rar_encryption.c` |
| `test_read_format_rar5_solid_encrypted.rar` | 拒绝 RAR5 solid 加密 | `test_read_format_rar_encryption.c` |
| `test_read_format_rar5_multiarchive.part01.rar` | 拒绝 RAR5 分卷首卷 | `test_read_format_rar5.c` |

上述测试按 BSD 2-clause 条款提供；完整版权声明、再分发条件与免责声明保留于 [LIBARCHIVE-LICENSE.txt](LIBARCHIVE-LICENSE.txt)，分发这些二进制样本时请一并保留。RAR4 测试版权作者是 Tim Kientzle、Andres Mejia 与 Michihiro NAKAJIMA；RAR5 测试版权作者是 Grzegorz Antoniak；加密测试的原始版权行为 `Copyright (c) 2003-2018`。本目录不包含 RAR 压缩器。

RAR5 内容对照直接重现上游 `verify_data()` 的公式，独立于待测系统解码器。RAR4 存储对照为上游明确给出的 `test text document\r\n`。RAR4 普通压缩的 [rar4-compressed-expected.json](rar4-compressed-expected.json) 由官方 7-Zip 独立读取并计算 SHA-256，CRC32 同时吻合上游样本的 `5e05a663` / `bec8a242`。运行验收时不会调用外部解码器生成预期摘要。符号链接必须保留“未验证”状态，不能令完整结果显示为相同。

检查目录另生成三组只改变声明并重算文件头 CRC 的 RAR 边界输入：RAR4 solid 标志、RAR5 新算法版本和 RAR5 128 MiB 字典。它们必须分别以不支持格式/资源限制拒绝，不让系统解码器尝试广告中的资源申请。

## 维护与重现

在项目根目录、Bash 环境中加载 `scripts/project-env.sh` 后，普通离线验收：

```bash
bash scripts/tests/check-archive-native.sh
```

仅在维护夹具时提供已经下载到项目内的官方 7-Zip 与 libarchive v3.8.9 源码，重新生成真实输入与摘要：

```bash
python3 scripts/tests/fixtures/archive-native/generate.py \
  .build-archive-native-checks/fixtures \
  --refresh-rar .build/research-7z-rar/upstream/libarchive-3.8.9/libarchive/test \
  --refresh-7z .build/research-7z-rar/7zip/7zz-arm64
```

`HelperFixture.c` 编译成独立测试进程，模拟非零退出、SIGKILL、无效 JSON、超过 16 MiB 的流式响应以及等待取消。它使用固定 64 KiB 输出缓冲区，不分配大量内存、不产生子进程。检查取消是否及时完成、进程是否被回收、错误是否阻止快照发布。60 秒超时与 RSS 看门狗的真实大负载不在这组快速验收中执行。

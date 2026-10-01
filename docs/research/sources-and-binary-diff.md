# 文件来源与二进制差异研究

研究日期：2026-10-01。范围：新 framework 的本地、SSH / SFTP、WebDAV、SMB、FTP 来源，以及十六进制与二进制差异。本文是设计依据，不代表这些能力已在 CrossDiff 实现；算法和服务器兼容性均未做实测。下文以「事实」「推论」「建议」区分证据与设计选择。

当前项目仍以本地比较为主。现有目录实现使用文件描述符、`lstat` / `fstatat`、分块 SHA-256、读取前后元数据核对和复制前重新检查；这些行为值得保留，但其中的 inode、device、POSIX 路径操作不能直接成为所有远程来源的公共契约。参见 [README](../../README.md)、[FolderComparison.swift](../../Sources/CrossDiffCore/FolderComparison.swift)。

## 1. SSH 远程文件夹是否就是 SFTP

**通常应实现为 SFTP over SSH，但 SSH 与 SFTP 不是同义词。** SSH 架构分别定义安全传输、用户认证和连接层；连接层可以启动 shell、执行命令或请求命名 subsystem。SFTP 是建立文件传输与目录访问能力的协议，OpenSSH 的 `sftp` 通过加密 SSH transport 完成操作。因此「SSH 已连接」并不说明 `sftp` subsystem 一定存在、获准或可访问指定目录。[RFC 4251 §1](https://www.rfc-editor.org/rfc/rfc4251.html#section-1)、[RFC 4254 §6.5](https://www.rfc-editor.org/rfc/rfc4254.html#section-6.5)、[OpenSSH sftp 手册](https://man.openbsd.org/sftp)

| 名称 | 已核实的含义 | 对 framework 的建议 |
| --- | --- | --- |
| SSH | 安全连接、认证和多通道；`exec` 与 `subsystem` 是不同请求。[RFC 4254 §6.5](https://www.rfc-editor.org/rfc/rfc4254.html#section-6.5) | 作为 transport/session 层；不把「会执行 shell」作为远程文件源的前提。 |
| SFTP | 有文件句柄、目录枚举、属性、按 offset 读取、链接操作；OpenSSH 公告 v3 及扩展。[SFTP v3 草案](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02)、[OpenSSH PROTOCOL §4](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL) | 默认的 SSH 文件来源 provider；协商版本与扩展，分别报告认证失败、subsystem 不可用、路径无权限。 |
| SCP | `scp` 是工具名；OpenSSH 9.0 起默认用 SFTP，`-O` 选择 legacy SCP。legacy SCP 依赖远端 shell。[OpenSSH scp 手册](https://man.openbsd.org/scp) | 不以 `scp` 命令是否成功来判定协议；不把 legacy SCP 当作可枚举、随机读取的目录 provider。 |
| SSH remote command | 可在允许 `exec` 的服务器上运行程序。[RFC 4254 §6.5](https://www.rfc-editor.org/rfc/rfc4254.html#section-6.5) | 可选的远端 hash / manifest / rsync 加速能力，需另行探测；不能假设有 POSIX shell、`find`、特定 hash 工具或任意命令权限。 |

**建议：** 产品入口显示「SSH / SFTP」，保存的连接类型明确为 `sftp`，SSH 跳板、主机密钥验证和认证属于连接配置。若确实希望支持「只有 SSH exec、没有 SFTP」的服务器，另定义有版本的 helper 协议或单独 command provider；这是一项额外兼容性承诺，不能靠解析 `ls` 输出隐式实现。SFTP v3 依据是历史 Internet-Draft，不应称为已发布的 SFTP RFC；实际互操作需同时看 OpenSSH 实现扩展。[SFTP 草案状态](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02)、[OpenSSH PROTOCOL](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)

## 2. 任意两种来源比较：统一读取契约，显式暴露能力差异

**建议：** 比较器只依赖两个独立的 `SourceProvider`；左、右均可是任一支持来源，包括两台不同的远端。任意来源互比应指内容可读取时均可比较，不应暗示都有相同的快照、远端 hash、写入或服务器间直传能力。ImHex 已在产品与 provider 层支持不同数据来源之间比较，可作为分层参考，但不能据此推断其支持本项目全部协议。[ImHex 官方仓库：data sources / diffing](https://github.com/WerWolv/ImHex)

### 2.1 建议的最小契约

以下是建议接口语义，不是现有代码或某个协议已经提供的 API。

| 能力 | 建议契约 | 必须保留的边界 |
| --- | --- | --- |
| `list` | 分批枚举直接子项，返回原始名称、opaque item ID、类型和可用属性。 | 无序、分页期间变化、部分失败均可表达；未知类型不能装作普通文件。递归由调度器控制并限制并发。 |
| `stat` / `revision` | 属性与 `RevisionEvidence` 分开；后者说明 token、证据强度及作用范围。 | inode、FileId、FTP `unique` 是身份线索，不能自动当内容版本；弱元数据不是不可变快照。 |
| `openRead` | 返回读取句柄、已知长度、revision 证据、访问能力。 | `sequential`、`range`、`seekableCache` 分别表达；未知长度允许逐步确定。 |
| `readRange` | 使用独立的 64 位字节偏移与长度；支持短读、EOF、取消和资源上限。 | 不能把一次 `read` 未填满当完整文件；不能因有 stream 就声称支持廉价随机访问。 |
| `snapshot` | 可选地绑定服务器快照、对象版本或本地稳定缓存。 | `observedAt` 时间和客户端下载副本不等于服务器原子快照；记录获取区间及一致性等级。 |
| `hash` | 返回算法、字节范围、digest、关联 revision 与来源。 | 未提供就是 unavailable；ETag、mtime、size、路径、服务器身份都不是跨来源内容 hash。 |
| 名称与链接 | 保留原始名字、显示名、比较 key、case/normalization 策略、链接目标。 | 冲突显式列出；不把本机文件系统的大小写或 Unicode 规范化规则强加给远端。 |
| `cancel` | 停止调度新工作，尝试取消 I/O，过期结果不得发布。 | 取消请求不等于服务器已停止执行；关闭连接不能回滚已完成写入。 |
| 缓存 | 按 endpoint、用户/授权域、item、revision、range 分区，设内存/磁盘配额。 | revision 变化时不能拼接旧、新范围；认证配置变化后不能复用其他身份的内容缓存。 |
| `write` | 独立能力：create、replace、rename、条件写入、durability。 | 不从 read 能力推导 write；记录「原子替换」「条件比较后替换」「持久化确认」各自是否成立。 |

这些差异来自协议事实：SFTP 带 offset 读与可选扩展，HTTP Range 可以被服务器忽略，FTP REST 是续传语义，SMB 有单独的取消与历史版本机制；公共层应保留这些信息，而非折叠成一个永远成功的文件系统接口。[SFTP §6.4](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02#section-6.4)、[HTTP Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2)、[FTP REST](https://www.rfc-editor.org/rfc/rfc3659.html#section-5)、[SMB CANCEL](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/57bae3d3-5dd7-4a5f-92cb-fc52e2087dad)、[SMB Timewarp](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/0eeb7dc1-f0e1-423a-a407-28b82496345b)

### 2.2 各协议的已知事实与设计后果

| 来源 | 枚举与读取事实 | 版本、名称与写入边界 | 建议 |
| --- | --- | --- | --- |
| 本地 | 当前 CrossDiff 用描述符扫描与顺序分块读取。[本地实现](../../Sources/CrossDiffCore/FolderComparison.swift) | 当前代码检查文件身份、修改时间、大小，并拒绝不安全链接路径；打开句柄不冻结文件内容。后一句是从其读取/核对流程得出的推论。[本地实现](../../Sources/CrossDiffCore/FolderComparison.swift) | 保留现有防护；需要稳定多次读取时创建受控缓存或接入明确的快照能力。 |
| SFTP | `OPENDIR/READDIR` 枚举；`READ(handle, uint64 offset, len)` 读取；`LSTAT` 与 `STAT` 区分是否跟随链接，`READLINK` 返回目标；v3 mtime 为秒级 UTC。[SFTP §5、§6](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02) | 基线操作没有通用的内容 revision / hash / 目录事务；OpenSSH `posix-rename`、`fsync`、`limits` 等需协商。[OpenSSH PROTOCOL §4](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL) | 读取前后 `FSTAT` 核对属于检测手段；不得宣称 snapshot isolation。不要默认跟随 symlink；扩展不支持时明确降级。 |
| WebDAV | `PROPFIND Depth:1` 可枚举直接成员；服务器可拒绝无限深度。内容读取用 HTTP GET，Range 支持可选。[RFC 4918 §9.1](https://www.rfc-editor.org/rfc/rfc4918.html#section-9.1)、[RFC 9110 §14](https://www.rfc-editor.org/rfc/rfc9110.html#section-14) | `getetag` / `getlastmodified` 继承 HTTP 语义；ETag 是 validator，不是规定算法的内容 hash。强 ETag + 条件请求可避免单资源 lost update；LOCK 是否支持及有效期需处理。[RFC 4918 §8.6](https://www.rfc-editor.org/rfc/rfc4918.html#section-8.6)、[RFC 9110 §8.8](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8) | 优先强 ETag；检查 `206` / `Content-Range`，收到 `200` 时转全量缓存策略。HTTP content coding 的范围针对编码后的表示，必须维持统一字节语义。[RFC 9110 §14.1.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.1.2) |
| SMB | 有目录枚举和基于句柄、偏移、长度的读取。[SMB directory](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/4cb0f00f-8eb7-465f-ac34-740593b74bc0)、[SMB read](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/ff304074-293b-4106-a5ea-c19c35ca736a) | lease 表示缓存协调；历史版本访问需 Timewarp token 且对应版本必须存在。Windows SMB2 服务器路径通常按官方产品行为使用不区分大小写的打开方式；不能据此概括所有服务器。[SMB lease](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/32c16a84-123f-40a9-99a8-00d34964308f)、[Timewarp](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/0eeb7dc1-f0e1-423a-a407-28b82496345b)、[Windows behavior](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/a64e55aa-1152-48e4-8206-edd96444e7f7) | 必须决定直接 SMB client 与已挂载共享两种接入边界。后者可经本地 provider 读取，但不能自动获得服务器版本、cancel、lease 的完整控制。 |
| FTP / FTPS | `MLSD/MLST` 提供机器可读枚举；`SIZE/MDTM/REST` 是扩展，`FEAT` 用于发现。REST STREAM 为续传起点，不保证像 SFTP 一样每请求都有 offset+length。服务器文件名可区分或不区分大小写。[RFC 3659](https://www.rfc-editor.org/rfc/rfc3659.html) | 传统 `LIST` 的格式偏向人阅读；`TYPE A` 与 `TYPE I` 有不同表示语义。[RFC 959 §3.1、§4.1.3](https://www.rfc-editor.org/rfc/rfc959.html) | 二进制及无损内容读取固定 image/binary 模式；无可靠范围能力时顺序下载到可寻址缓存。MLSD 缺失需独立兼容策略，不能悄悄漏文件。 |

**FTP 加密需要单独说明。** 普通 FTP 的控制、密码及数据不加密；FTPS 是 FTP 加 TLS，RFC 4217 分别处理控制连接与数据连接保护，数据保护使用 `PROT P`。SFTP 是另一套协议，经 SSH 使用，不是「FTP 打开 TLS」；FTP over SSH tunnel 也不自动变成 SFTP。[RFC 2577 §5–6](https://www.rfc-editor.org/rfc/rfc2577.html#section-5)、[RFC 4217 §3、§9](https://www.rfc-editor.org/rfc/rfc4217.html)、[OpenSSH sftp](https://man.openbsd.org/sftp)

**建议：** 保留用户要求的 FTP 兼容性，连接页明确提供「FTP（未加密）」与「FTPS（TLS）」；加密状态展示实际协商结果，连接失败时不静默降级到明文。WebDAV 同样区分 HTTP / HTTPS；SMB 的签名、加密、版本协商不能只用「已连接」概括。这是产品与能力设计建议，不是新增实现。

### 2.3 时间、hash 与快照的可信程度

**事实：** SFTP v3 mtime 是秒，FTP 支持自己的 time-val 精度，HTTP Last-Modified 与 ETag 也有不同强弱验证规则。因此不能跨来源用「同 size + 同 mtime」证明字节相同，更不能仅以 timestamp 排序确定谁是最新内容。[SFTP file attributes](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02#section-5)、[FTP time-val](https://www.rfc-editor.org/rfc/rfc3659.html#section-2.3)、[HTTP validators](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8)

**推论：** 两边逐项列目录、读文件并计算 hash，只能证明各次读到的字节之间的关系；没有共同快照机制时，不能证明「这两个目录在同一个时刻完全一致」。扫描期间新增/删除文件、同长度改写、修改时间恢复、跨多个 read 的并发改写都可能产生混合观察；读取前后属性一致也不是通用事务保证。协议提供的是单个资源/句柄的操作以及可选版本机制，未在上述共同基线中提供跨两个服务器的原子读取。[SFTP operations](https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02#section-6)、[WebDAV consistency](https://www.rfc-editor.org/rfc/rfc4918.html#section-8)、[SMB Timewarp](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/0eeb7dc1-f0e1-423a-a407-28b82496345b)

**建议：** 对每项结果记录证据等级，而非只有 `same/changed`：

1. `metadataOnly`：仅元数据候选，界面不得标为内容已验证。
2. `contentCompared`：完整读取后逐字节比较，或按明确策略比较相同算法的全量 digest；hash 相等是该策略下的内容证据，不是数学上的无碰撞证明。
3. `revisionBound`：所有读取绑定同一强 validator / 版本；token 只在其提供方与资源作用域内解释。
4. `snapshotBound`：服务器明确提供并成功绑定的快照；左右快照分别记录，不编造跨服务器共同时间点。
5. `unstable/partial/unreadable`：扫描变化、只完成部分或读取失败，不能混成「相同」。

**事实与推论：** rsync 的原始算法让一侧发送块 checksum，另一侧搜索任意偏移的匹配，以减少需要传输的内容；这是需要双方算法参与的数据传输方案。它不意味着任意 SFTP / WebDAV / FTP 服务器都能计算块签名，也不保证生成适合人阅读的最小编辑脚本。原论文使用的旧 checksum 选型不应直接成为新实现的安全承诺。[rsync 原报告](https://rsync.samba.org/tech_report/)、[算法步骤](https://rsync.samba.org/tech_report/node2.html)、[匹配逻辑及概率边界](https://rsync.samba.org/tech_report/node4.html)

**建议：** 基线仍允许全部来源只提供列表和字节流。远端 hash、块签名、服务器侧 copy 是可选加速；没有此能力时，完整内容比较确实可能需要把双方相关字节传到客户端。缓存总量与网络量必须可见，并允许暂停/取消，不能把一次全量扫描伪装成低流量元数据检查。

### 2.4 写入、复制与取消

**事实：** WebDAV 可用 `If-Match` 等条件请求处理单资源并发修改。OpenSSH POSIX rename 扩展是 rename 语义，`fsync` 又是独立操作；它们不包含「仅当目标仍是某个旧 hash 时替换」的通用前提。SMB CANCEL 是尝试取消，目标操作仍可能完成。[RFC 4918 §7.2](https://www.rfc-editor.org/rfc/rfc4918.html#section-7.2)、[OpenSSH PROTOCOL](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)、[SMB cancel handling](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/57bae3d3-5dd7-4a5f-92cb-fc52e2087dad)

**建议：** 未来跨来源复制复用当前「预览 → 重核对 → 执行」行为，但准确标示保障等级。原子替换防止读者看到半文件，条件写入防止覆盖他人的新版本，durability 表示落盘承诺，三者不可互相替代。缺少原子条件写入时，check-then-rename 仍有竞态；只有「覆盖前再 stat」不足以承诺零丢失更新。只做比较的基础来源支持，不需要因此扩大为完整同步、批量删除或跨服务器事务。

## 3. Hex / binary diff 应拆成四层

| 层 | 输出及用途 | 事实依据和边界 |
| --- | --- | --- |
| 十六进制显示 | 地址、hex bytes、可选文本解释；选择、复制、跳转 offset。 | 改变呈现，不改变字节含义；endianness 属于数值解释。Hex Fiend 同时有 hex 与 data inspector。[Hex Fiend 官方功能](https://github.com/HexFiend/HexFiend) |
| 字节差异与对齐 | 相同区间、插入、删除、替换；左右分别有原始偏移。 | 只比较相同 offset 会在插入后产生大片差异。Hex Fiend 提供考虑插入删除的 diff；ImHex 同时提供朴素逐字节和带窗口的算法。[Hex Fiend release notes](https://hexfiend.github.io/HexFiend/ReleaseNotes.html)、[ImHex Diffing](https://docs.werwolv.net/imhex/views/diffing) |
| Delta / patch | 根据旧数据和 patch 精确重建新数据，优化更新体积或传输。 | bsdiff / xdelta 属于此类；小 patch 不等于适合阅读的连续对齐。VCDIFF 的 ADD / RUN / COPY 描述重建，不定义 UI 语义。[bsdiff 作者说明](https://www.daemonology.net/bsdiff/)、[RFC 3284](https://www.rfc-editor.org/rfc/rfc3284.html) |
| 结构化语义比较 | 字段、记录、节区、指令、对象等领域单位。 | 需要具体格式的解析器与对应规则；ImHex pattern language 可解析结构，但「有解析器」不自动构成该格式的语义 diff / merge。[ImHex 官方格式能力](https://imhex.werwolv.net/)、[ImHex 仓库](https://github.com/WerWolv/ImHex) |

**建议：** 基础版把 hex 视图和字节级插入/删除比较列为独立可验收能力；delta 导出和结构化插件保留独立接口。压缩包、重定位后的可执行文件或重新加密的文件即使语义变化很少，也可能具有大量字节差异；字节层只承诺报告字节关系，不推断业务含义。

## 4. 算法研究与推荐路径

### 4.1 已核实候选

| 候选 | 事实 | 适用建议 / 限制 |
| --- | --- | --- |
| 同 offset 分块比较 | ImHex 的 simple 算法比较同地址字节。[ImHex Diffing](https://docs.werwolv.net/imhex/views/diffing) | 用作最快的完整性/差异区间模式。顺序读取可界定缓存；不能宣称识别插入删除。 |
| Myers 最短编辑脚本 | Myers 1986 论文给出 `O(ND)` 算法与线性空间改进；`D` 为编辑距离，差异大时不等于线性时间。[原论文，出版方](https://link.springer.com/article/10.1007/BF01840446)、[原论文 PDF 镜像](https://neil.fraser.name/writing/diff/myers.pdf) | 适合小输入或局部窗口的字节序列；需时间、工作量、内存预算。不能把面向文本的全量路径数组原样套到几十 GB。 |
| Hex Fiend diff | 官方发布说明称其为 LCS-based；`HFByteArrayEditScript` 保留两输入、支持进度和取消，并提示输入变化会使脚本失效。[release notes](https://hexfiend.github.io/HexFiend/ReleaseNotes.html)、[API 文档](https://hexfiend.github.io/HexFiend/docs/interface_h_f_byte_array_edit_script.html) | 优先调研其原生 macOS 数据/视图分层与对齐交互；公开的“大文件打开”能力不等于任意大文件 pair 的 diff 性能承诺。 |
| ImHex diff | 官方说明有 byte-by-byte 与名为 Myers bit-vector 的窗口算法，窗口限定向前搜索，后者较慢。[ImHex Diffing](https://docs.werwolv.net/imhex/views/diffing) | 可作为模式/预算 UI 参考；该文档的 bit-vector 名称不能直接等同于 Myers 1986 的 `O(ND)` SES 实现。 |
| rsync rolling checksum | 用固定块签名在另一内容的任意偏移查找匹配，再输出块引用和字面量。[rsync 算法](https://rsync.samba.org/tech_report/node2.html) | 可借鉴为大文件重同步锚点；避免把节省传输、移动块匹配和最短显示 diff 混成一个指标。 |
| bsdiff 4 | 作者给出的生成内存为 `max(17n, 9n+m)+O(1)`，apply 为 `n+m+O(1)`；针对二进制 patch。[作者说明](https://www.daemonology.net/bsdiff/) | 可做 patch 大小基准；不选为低内存交互浏览默认引擎。此公式属于作者所述实现，不推广到所有派生实现。 |
| xdelta3 / VCDIFF | 是差分压缩库/工具；源窗口、输入窗口、指令缓存等均影响内存与匹配范围；设计允许固定内存预算，预算不足影响压缩比。[作者仓库](https://github.com/jmacd/xdelta)、[内存调优](https://jmacd.github.io/xdelta/tuning-memory/) | 未来 patch 功能候选。检查具体版本与构建参数，不把“streaming API”视作所有源都无需寻址/缓存的保证。 |

原论文可读副本仍是 Myers 原文，非二手算法综述；出版方链接给出书目信息。Hex Fiend / ImHex 的上述结论来自官方仓库 README、发布说明及公开 API/使用文档。本次 web 读取具体 diff 实现源文件失败，**没有完成源代码级复杂度或取消检查审计**，也没有安装或执行它们。

### 4.2 建议的分阶段算法

1. **先建立正确的 ByteSource 与结果格式。** 每侧为独立原始字节域；结果以 `equal/insert/delete/replace` span 描述 source、destination 范围，附版本、算法、预算、是否完整/精确。不把十六进制文本交给已有文本 diff，也不使用 UTF-16 坐标表示二进制 offset。
2. **提供同 offset 完整比较。** 顺序分块读取，合并相邻差异 span；首个不同可快速返回，但“相同”必须完成所需范围。缓存有界；差异 span 本身可能很大，结果列表也要分页或落盘。
3. **小文件 / 小间隙精确对齐。** 公共前缀、后缀剥离后，使用有预算的最短编辑脚本实现；超预算的区域返回粗粒度 replace，显式标记对齐精度降低，不输出伪造的精确结果。Myers 的时间依赖 D，正是需要预算的依据。[Myers 原论文](https://link.springer.com/article/10.1007/BF01840446)
4. **大文件采用锚点 + 局部精化。** 研究 rolling checksum 或内容定义分块生成候选锚点，字节核对候选，选取单调锚点链，再对间隙做局部 diff；重复块需确定性 tie-break，移动块可另作注释。这是工程建议，不能宣称等于全局最短编辑脚本；锚点与 lookahead 会牺牲部分全局最优性。rsync 的滚动匹配与 ImHex 的窗口都提供了相关设计参照。[rsync rolling checksum](https://rsync.samba.org/tech_report/node3.html)、[ImHex 窗口](https://docs.werwolv.net/imhex/views/diffing)
5. **patch 保持独立。** 若加入导出，评测 xdelta / bsdiff 的生成、应用、错误 base 检测和重建校验，不能用 patch size 决定 UI 的阅读质量。[xdelta](https://github.com/jmacd/xdelta)、[bsdiff](https://www.daemonology.net/bsdiff/)

**建议的偏移映射：** 用分段双坐标而非固定 delta；equal span 可以一一映射，insert/delete 对应的是对侧边界，replace 可能只有区间对应。地址栏永远标原始文件 offset；对齐空白不是文件字节。选区跨 gap 的复制应只取本侧真实字节，并明确 raw bytes、hex string、文本解释的区别。类似约束也适用于现有文本删除预览，但二进制应有独立的 byte offset 类型。

**三方边界：** 两方编辑脚本的可用性不自动提供通用三方合并。三方必须拥有 base，分别构造 `base→left`、`base→right` 对应关系；重叠修改、重复区、移动与格式内部偏移更新都需要冲突策略。建议通用二进制层只提供三方关系和冲突检测，自动应用限定为可证明不相交且字节前提仍满足的编辑；没有领域插件时不承诺生成有效的文档、数据库或可执行文件。此段是对二进制重建与序列对齐能力边界的设计推论，非 bsdiff / VCDIFF 已提供的三方能力。[VCDIFF 重建模型](https://www.rfc-editor.org/rfc/rfc3284.html)、[Hex Fiend edit script 输入约束](https://hexfiend.github.io/HexFiend/docs/interface_h_f_byte_array_edit_script.html)

## 5. 大文件、缓存、mmap 与远程 seek

**事实：** Hex Fiend 将 byte array、byte slice、file reference 分层，官方说明不会把整个文件保存在内存。xdelta3 文档同样区分 source buffer、window、指令数据，其源文件读取使用 buffer，不是 mmap。[Hex Fiend 类列表](https://hexfiend.github.io/HexFiend/docs/annotated.html)、[官方 README](https://github.com/HexFiend/HexFiend)、[xdelta memory](https://jmacd.github.io/xdelta/tuning-memory/)

**事实：** Apple 的归档文件映射指南明确指出网络/可移除文件丢失可能触发 bus error，网络映射访问还可能阻塞等待超时。该文中的 4 GB 虚拟地址空间讨论是旧时代背景，**不能作为现代 64 位 macOS 的上限**；可借鉴的是 I/O 故障模型和局部映射建议。[Apple Mapping Files Into Memory](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/MappingFiles.html)

**事实：** xdelta 对 non-seekable source 有回看窗口约束；decoder 窗口不足可能失败，某些校验模式还要求 seekable source。因此 streaming、可随机读取、稳定 revision 是三个不同能力。[xdelta non-seekable sources](https://jmacd.github.io/xdelta/non-seekable-source/)

**建议：**

- hex 视图只取可见范围及受限预取，不能先格式化整文件。以顺序分块流为通用扫描底座，以范围缓存支持浏览和局部对齐。
- remote provider 支持 range 时合并小请求、限制并发和预读距离；高延迟下逐字节 remote read 不可接受。HTTP 不接受 Range / FTP 无可靠 seek 时下载到项目/应用受控缓存，再由同一 ByteSource 接口读取。
- mmap 仅作为稳定、本地、受控缓存的可选优化，并与普通 range read 同测；绝不直接把 SSH/WebDAV URL 当可 mmap 文件，也不默认 mmap 挂载 SMB 文件。
- 总预算包括输入 cache、锚点表、diff 工作区、result spans、UI buffers 与临时磁盘。分块读取只能限制其中一项；大量碎片差异和巨量目录项仍会耗尽其他项。
- 缓存获取过程中检测 revision 变化即失效，不拼接两代内容；若只有弱属性证据，结果保留 `bestEffort`。后台完成后再核对比较任务版本，取消/换来源后的结果不得覆盖当前视图。
- 错误显式区分认证/权限、连接中断、文件变化、存储空间不足、不支持 seek、超过工作预算；可以继续浏览已缓存区域，但不将未读取区域标为相同。

## 6. 待执行的基准与验收矩阵

以下均为**建议实验**，不是已得到的数据。硬件、OS、算法版本、provider 版本、服务端配置、冷热缓存、连接加密状态都要随报告保存。

| 维度 | 建议样本 | 主要验证 |
| --- | --- | --- |
| 来源配对 | local、SFTP、WebDAV、SMB、FTP 五类底层 provider 的全部 25 个有序配对；同类含不同服务器；FTPS、SSH 跳板作为变体。若单独承诺 SSH command provider，扩大矩阵。 | 任意来源互比没有遗漏；左右交换语义正确；不依赖两端相同协议。只读比较与写入验收分开。 |
| 协议差异 | SFTP subsystem 禁用/仅 SFTP；扩展缺失；WebDAV Range 忽略/ETag 缺失/weak ETag；SMB mounted/direct；FTP 无 MLSD/REST、FTPS 数据通道策略。 | capability 探测与降级可解释；失败不被当空目录或文件不存在。 |
| 规模 | 0 B、1 B、1 KiB、1 MiB、64 MiB、1 GiB、10 GiB；>4 GiB 偏移；目录 10³、10⁵、10⁶ 项；深目录。 | 首屏、首差异、完成时间；峰值 RSS、临时磁盘、结果数量；64 位加减边界与 EOF。大规模可按资源分阶段执行。 |
| 变化模式 | 相同；首/中/尾单字节替换；1 B、块大小±1 插入/删除；跨窗口变化；大段移动；等长度全随机；全零/周期重复。 | 正确率、重同步距离、碎片数、预算退出；同 offset 与插删模式的结果差异符合描述。 |
| 真实内容 | 不压缩数据、压缩包、可执行文件、数据库副本、媒体文件；有已知生成操作的合成样本。 | 不把字节准确性与语义可读性混淆；不把某类优秀表现推广到所有文件。 |
| 网络 | RTT 1/20/100/300 ms，带宽 10/100/1000 Mbps；中途断开、超时、重连、冷热缓存。 | 总下载/上传字节、请求数、p50/p95 UI 响应、预取浪费、取消后残余流量。 |
| 一致性 | 扫描间新增删除；读取中截断/覆盖；同 size/mtime 改写；validator 变化；缓存恢复后远端更新。 | 无混代范围发布；完整/部分/不稳定状态准确；强证据与弱证据区分。 |
| 路径 | 大小写冲突、NFC/NFD、非 ASCII、不可解码名称、空格/换行、符号链接与环、类型冲突。 | 名称可回溯；不越根、不随意跟链；无法无损表示时显式阻断对应操作。 |
| 偏移与显示 | 不同 bytes-per-row、选区跨 gap、多字节文本解释、末尾短行、巨量差异跳转。 | 地址始终对应原始 byte；复制不含占位；左右滚动映射不混淆。 |
| 补丁（可选） | bsdiff / xdelta，不同内存预算；错误 base、损坏/truncated patch。 | 重建逐字节正确；patch 大小、生成/apply 时间、内存分别报告；失败不覆盖原文件。 |
| 三方（后续） | 不相交、重叠、同边界双插入、重复块、移动+编辑、base 不匹配。 | 冲突与不确定性显式，不自动拼出「看似成功」的损坏二进制。 |

**建议的正确性判据：** 小样本以独立 oracle 检查最短编辑距离；所有完整 diff 的 span 必须按序覆盖输入并能精确重建另一侧；相等 span 做字节核验；交换两侧后的 insert/delete 对偶应成立。启发式模式检查覆盖、重建和预算声明，不强行要求全局最短。性能先取得实测分布再定产品文件上限，不能从 Hex Fiend 的打开样例或算法的大 O 直接写出 CrossDiff 的容量承诺。

## 7. 可纳入框架方案的结论

- 基础来源层采用 capability-aware provider；SSH 文件浏览默认由 SFTP 实现，SSH exec 加速与之分开。普通 FTP、FTPS、SFTP 的安全语义明确区分。
- 任意两来源的字节比较可以通过统一列表与读取契约成立；可选能力影响速度和一致性，不应改变「能否基本比较」的模型。
- “内容相同”的证据、读取版本绑定、服务器快照、跨目录原子一致性分别表达；跨服务器扫描不承诺共同瞬时快照。
- 基础 binary diff 采用 hex 呈现、原始字节坐标、同 offset 比较和受预算控制的插删对齐；patch、格式语义与三方合并作为独立能力。
- 下一步应做 provider 契约小型原型和有上限的算法基准。本轮未选择具体网络库、未修改源码、未执行服务器互操作或大文件性能测试。

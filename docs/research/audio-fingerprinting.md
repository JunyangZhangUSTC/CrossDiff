# 音频指纹与片段对应研究

核验日期：2026-10-02。范围为同一录音经剪辑、拼接、重排、变速或变调后的局部对应，兼顾音乐与语音。本文只做一手文献与源码核验，没有安装、编译、运行这些算法，也没有测得 CrossDiff 的准确率或性能。引用 `master` 是本次查阅状态，接入时必须锁定提交及依赖。

## 推荐取舍

1. **audfprint：无明显时间／音高变换的研究基线。** 有可调用 Python 实现和局部时间支持范围，适合先校验剪辑、移位、重排问题的评价方法。
2. **Panako 2：独立变速／变调的增强主候选。** 原作者论文明确覆盖独立时间与频率缩放，源码有两个时间区间及变换因子的输出。它仍是片段检索器，需要 CrossDiff 编排多段候选、边界细化与重复片段歧义。
3. **Olaf：轻量原生交付候选。** C 核心比捆绑 Python／JVM 更易接入 Swift；不能因此替代 Panako 的独立大幅变换能力，须用同一测试集比较。
4. **Chromaprint 不作为本需求主引擎。** 官方定位是近似相同录音、整曲识别和长流监测，专门牺牲部分精度／鲁棒性换取紧凑指纹与检索性能，不能因为有 C 接口就认为适合任意短剪辑与变调。[audfprint](https://github.com/dpwe/audfprint)、[Panako](https://github.com/JorenSix/Panako)、[Olaf](https://github.com/JorenSix/Olaf)、[Chromaprint 定位](https://github.com/acoustid/chromaprint#chromaprint)

这是候选优先级，不是已经完成的选型。先验证同一录音的对应；不同人说同一句话、同曲不同演奏属于更高层的语义／音乐结构匹配，不应标成“相同录音片段”。

## audfprint：可直接建立的基线

作者 Dan Ellis 的实现采用频谱地标指纹。命令行可以只把 A 加入一份会话索引，再查询 B，无须云服务或大型曲库。`--find-time-range` 返回 query 与 reference 上的匹配支持范围；`--max-matches` 默认只有 1，比较整段剪辑时要显式增大。项目为 MIT，当前 requirements 包括 NumPy、SciPy、docopt、joblib、psutil，音频读取默认依赖 FFmpeg。[项目与用法](https://github.com/dpwe/audfprint)、[依赖清单](https://github.com/dpwe/audfprint/blob/master/requirements.txt)、[许可证](https://github.com/dpwe/audfprint/blob/master/LICENSE)

源码的 `_exact_match_counts` 支持同一 reference ID 返回多个时间偏移峰；每个候选仍以近似固定时差筛选。`_calculate_time_ranges` 对支持点取分位数，因此返回的是证据覆盖区间，不能直接称为逐采样精确剪辑边界。同一偏移下相隔很远的两段也可能落入一个外包区间，产品还需检查内部连续性。它没有 Panako 那样显式估计独立时间／频率缩放的接口；可以容忍多少轻微漂移必须实测，不能宣称完全不容忍或保证某个百分比。[匹配源码](https://github.com/dpwe/audfprint/blob/master/audfprint_match.py)

默认时间字段仅 14 bit，以约 23 ms 为单位，约 6 分钟后时间会混叠；两文件场景可增大 `maxtimebits`，但必须覆盖长播客验收。README 的数秒查询示例只证明示例成功，不能当通用最短片段；默认“至少若干匹配哈希”也不是时长保证。作者另给出寻找电视广告／精确声音片段的流程，说明目标不局限整首音乐，但没有因此得到中文对白或环境声的可靠性结论。[时间编码限制](https://github.com/dpwe/audfprint#scaling)、[作者广告定位示例](https://github.com/dpwe/audfprint/blob/master/searching_for_ads.md)

建议只作为项目内原型工具启动，生成私有临时索引，不读取用户提供的 pickle 指纹库。若正式捆绑，Python、科学计算运行时、解码器均须自行提供或改为明确的 PCM 适配接口，不能要求用户安装全局依赖。FFmpeg 的许可范围由实际构建选项决定，不能用 audfprint 的 MIT 许可证覆盖整个发行包。[FFmpeg 法律与许可说明](https://ffmpeg.org/legal.html)

## Panako 2：能力证据与重要接口陷阱

作者 2022 年章节评估的是 2021 更新后的实现，锁定提交 `6cf936730131d71c94c562a06a1a791e09b4c520`。该实现改用 constant-Q non-stationary Gabor transform、近似哈希检索与允许线性时间漂移的匹配。论文脚注明确时间伸缩与音高因子不必相等；因此它的能力并非仅限“磁带式加速时音高一起升高”。评估用 FMA 音乐、20 秒查询，分别测试变调、时间伸缩、联动速度变化约 ±16%；这不是语音、极短片段、任意大幅变换或任意重排的保证。[作者章节，第 11–16 页](https://0110.be/files/publications/2022/2022.duplicates-author_version.pdf)

### 不要直接调用 `panako same`

`Same.java` 实际硬编码 `OlafStrategy`，最后只打印有指纹匹配的秒数比例。即使项目叫 Panako，这个命令也不是变速／变调 Panako 策略，更没有直接交付全部局部对应图。[Same.java](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/cli/Same.java)

可落地的原型是一个小型 Java 桥，在**同一个工作进程**中，先配置再构造 `PanakoStrategy`，保存 A 的指纹到内存并查询 B。构造器已有内存存储分支。至少显式设置：

```text
PANAKO_STORAGE=MEM
PANAKO_CACHE_TO_FILE=FALSE
PANAKO_USE_CACHED_PRINTS=FALSE
PANAKO_USE_GPU_EP_EXTRACTOR=FALSE
```

否则仅指定 MEM 仍可能通过默认启用的缓存访问磁盘。配置、JNI 解包、日志、Java 临时目录也要指向项目内隔离目录；避免调用上游会写入用户 home 的安装步骤。配置与存储存在全局状态，建议每个比较任务用受控进程生命周期隔离，取消时终止该工作进程。[策略构造与读取路径](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/strategy/panako/PanakoStrategy.java)、[默认配置](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/util/Key.java)

### 时间范围不是完整剪辑图

`QueryResult` 提供 queryStart/queryStop、refStart/refStop、score、timeFactor、frequencyFactor、percentOfSecondsWithMatches。应保留原始字段，使用已知变换样本验证方向和单位后，才换成用户看到的速度倍率／半音差；源码注释对 factor 的百分比／比例表述并不完全一致。score 是匹配计数，覆盖秒数比例是覆盖指标，都不能直接显示成“正确概率”。[QueryResult.java](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/strategy/QueryResult.java)

当前 `query` 按 reference identifier 汇总，利用首尾匹配拟合一条时间关系，并为每个 identifier 至多生成一个结果。把 `maxNumberOfResults` 调高，不能自动得到同一 A 中全部剪辑／重复片段。需要 CrossDiff 的多尺度重叠窗口、双向检索、候选去重和一致性检验；频繁剪辑或相同副歌会产生歧义，不能强制唯一对应。

自带 `monitor` 的循环条件为 `t + stepSize < totalDuration`，原样使用会漏掉不足整窗的尾段，也可能不处理短输入。桥接层须覆盖首尾、不完整窗并显式恢复全局时间，而不是把 monitor 输出直接当全部结果。[query／monitor 源码](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/strategy/panako/PanakoStrategy.java)

默认最短匹配持续时间为 5 秒，时间及频率因子筛选范围约 0.8–1.2；这是接受条件，不是检出保证。缩短时长阈值可能显著增加误匹配，必须用短语音、重复节奏、静音和负样本校准。局部连续变速需要切得更细或另用局部对齐，不能假设一条线能解释整段。[阈值配置](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/util/Key.java)

### 运行时和发行负担

当前 `build.gradle` 标版本 2.1、Java target 11；依赖 lmdbjava 0.9.1、TarsosDSP core/jvm 2.5、JGaborator 0.7 等。JGaborator 经 JNI 调用 C++ Gaborator，所以捆绑单个 JAR 还不够。README 早段说 M1 尚需额外处理，2.1 changelog 又称已支持 M1，且 changelog 提到 Java 17，均与部分旧描述不一致。应锁版本，实际验证 macOS arm64 的 JRE、JNI、签名与隔离运行，不沿用旧安装段的结论。[构建文件](https://github.com/JorenSix/Panako/blob/master/build.gradle)、[README／changelog](https://github.com/JorenSix/Panako#changelog)

`PanakoStrategy` 当前从 `AudioDispatcherFactory.fromPipe` 解码；不能仅凭 `DECODER` 配置注释就认为已经有可无缝替换成 Apple 解码的入口。第一轮可用隔离的 FFmpeg 原型；正式原生解码路线需要补 PCM 适配边界并验证样本率、时延和时间映射。Panako 为 AGPL-3.0-or-later，与本项目方向一致，但各运行时和原生依赖仍需逐项保留许可证、源码及构建说明。上游另有算法专利提示，开源许可证不等同于专利结论；此研究没有做专利有效性或地区法律判断。[策略源码与许可证头](https://github.com/JorenSix/Panako/blob/master/src/main/java/be/panako/strategy/panako/PanakoStrategy.java)、[上游说明](https://github.com/JorenSix/Panako)

## Olaf 与 Chromaprint 的交付价值

Olaf 当前有可移植 C 核心和独立解码层，主 CLI 使用 Zig；文档展示 macOS arm64 构建，并提供内存与 LMDB 后端。可以研究用 Apple 解码／重采样喂给 C 核心，避免整个 CLI、FFmpeg 或网络服务一并捆绑。当前 CLI 的 `query --fragmented` 已支持分窗和 JSON 输出，方便用作原型。AGPL 主许可及 PFFFT、LMDB 等依赖要分别审计。[Olaf 官方仓库](https://github.com/JorenSix/Olaf)

**待核验边界：** 本轮没有完成 Olaf 当前 C 匹配器的变换不变性源码审计；不能把 Panako 项目内的 OlafStrategy、独立 Olaf 仓库和 PanakoStrategy 视为同一种实现。它是轻量基线候选，不承诺大幅独立变速／变调，也不能用未在语音上验证的音乐结果替代验收。

Chromaprint 可选 Apple vDSP FFT，适合原生 C 桥；其官方定位限制使它更适合近重复文件辅助判断，而非本轮主要片段匹配。若试用，应直接传入本地 PCM，不把 AcoustID 在线查询引入 CrossDiff。[Chromaprint 构建与定位](https://github.com/acoustid/chromaprint)

## 必须验证的语音与剪辑边界

2020 年 SAMAF 论文以 VoxCeleb1 的 1–6 秒片段比较旧版 Panako，发现音乐算法在短语音、时间／频率变换上表现很弱。它早于 Panako 2021 更新，不能据此宣称新版也失败；但它足够说明“音乐有效”不能直接推出“短对白有效”。当前没有核实到足以替 CrossDiff 保证新版中文语音、环境声、多段重排性能的一手实验。[SAMAF 作者版，实验与表 5](https://www2.cs.uh.edu/~gnawali/papers/audiofingerprint-tomm20.pdf)

建议固定一套项目内可再生、有真实来源对应标签的评价数据，并分别报告音乐／语音：

- 同一录音切段、插入、删除、重排、重复插入和交叉淡化；测试 1／2／5／10／20 秒片段。
- 只变时间、只变音高、两者独立组合、普通播放速度联动变化；局部不同倍率和缓慢漂移分开列项。
- AAC／MP3 重编码、响度变化、EQ、背景噪声、左右声道不同／反相；同时保留不同录音的负样本。
- 静音、持续音、重复鼓点、音乐副歌、重复说同一句话等低辨识度／多解样本。
- 除检出率外，统计误报、双侧边界误差、变换估计误差、多个正确对应的召回、取消延迟、内存和完整时长处理；不能仅展示整文件相似度。

两文件确实省掉大库索引、服务和规模检索的负担，但局部搜索、未知变换、重复片段歧义与边界估计仍然存在。可以从成熟实现构建实用产品；不能用“一次全局匹配 + 一个百分比”替代音频 diff。

# 音频局部对齐：FMP、Sync Toolbox 与 MATCH

调研日期：2026-10-02。范围：为两个音频寻找对应片段，不涉及音频库检索服务。本轮只调查官方文档、论文入口与源码，未运行音频准确率或性能实验，未增加应用功能。

## 结论与适用场景

**可行，但“只有两个文件”并没有消除片段搜索和错误匹配的问题。** 两个文件省去了大型索引服务；仍然要处理双方未知的剪辑位置、重复、一对多、顺序改变、局部时间映射与变调。建议将“同一录音的加工版本”作为主任务，音乐与语音分别测试；“不同演奏的同一作品”是另一种相似性任务，不将旋律或和声相似标成“同一录音”。这是针对 CrossDiff 的产品判断，并非任何单一库的能力承诺。

## 对齐问题不能混用

| 方法 | 已核实的任务定义 | 对 CrossDiff 的含义 |
| --- | --- | --- |
| 整段 DTW | 从双方开头到结尾，以单调时间路径对应整个序列。 | 适合结构相近的版本；不能用一条路径表示任意片段重排。 |
| Subsequence DTW | 一侧整个查询，对应另一侧一个未知位置的子段。 | 已选中片段的“在另一侧定位”比较贴合。 |
| Common subsequence / 局部对齐 | 双方起止都未知，通过正相似分数和负惩罚寻找高分局部路径。 | 更接近双方均被剪辑的共同片段发现。 |
| Partial matching | 允许跳过更多内容，但对应位置仍严格单调。 | 能处理间隔，仍不能表达任意重排。 |

上述定义来自 [FMP Common Subsequence Matching](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C7/C7S3_CommonSubsequence.html)。其中的 Python/Numba 示例回溯出一个最高分局部路径；参考函数没有承诺返回全部重排片段，也没有提供一对多关系的产品模型。

**工程建议：** 输出一组独立的片段对应，而不是强行给整条音频一个单调映射。例如左侧 `A–B–C`、右侧 `C–A–A`，需要 `A→A₁`、`A→A₂`、`C→C` 等关系；不能为保留一个全局顺序而丢弃正确关系。多候选提取、近重复路径合并、重叠和冲突处理必须另外设计。已找到一对片段之后，再在片段内部运行受约束的 DTW 或局部精修。

## libfmp 可以复用什么

已直接读取官方 [`libfmp/c7/c7s3_version_id.py`](https://github.com/groupmm/libfmp/blob/master/libfmp/c7/c7s3_version_id.py)：

- `compute_accumulated_score_matrix_common_subsequence` 与 `compute_optimal_path_common_subsequence` 是局部对齐参考实现。
- `compute_sm_from_wav` 提取 STFT chroma，再计算 CENS、路径增强和阈值化的相似度矩阵。接口接受两段音频。
- 参考默认 `tempo_rel_set=[0.66, 0.81, 1, 1.22, 1.5]`，而 `shift_set=[0]`。**默认并不搜索变调**。这些是相似矩阵增强的采样参数，不能翻译成“保证识别此范围内的所有变速”。

项目由 FMP 作者团队维护，定位为教学与研究参考实现；应作为可核验基线，不应跳过产品测试直接宣称适用于任意音频。[libfmp 官方说明](https://github.com/groupmm/libfmp)

代码许可证已检查为 **MIT**，保留版权及许可文本即可按其条款复用；不能由此推定教材、网页图片和示例音乐具有同样授权。[libfmp LICENSE](https://github.com/groupmm/libfmp/blob/master/LICENSE)

## 变速和变调的边界

FMP 的路径增强会沿多个相对速度方向平滑相似矩阵；这是增强局部结构的方法。平滑太强会模糊短片段与准确边界，因此“粗定位”和“精确时间边界”不应使用同一分辨率。[FMP Path Enhancement](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C4/C4S2_SSM-PathEnhancement.html)

Chroma 循环移位能比较半音移调的音乐和声，12 个移位覆盖一个八度的音级类别；一个八度后向量回到原样。该方法有意丢失部分音域信息，最大移位分数也不代表绝对相似程度已经足够高。[FMP Transposition Invariance](https://www.audiolabs-erlangen.de/resources/MIR/FMP/C4/C4S2_SSM-TranspositionInvariance.html)

**由此推得的工程边界：** chroma 适合作为音乐候选的补充，不宜作为语音、环境声以及“同一录音”的唯一证据。相似和弦、节奏和重复段落可能来自不同录音。对于用户目标，应优先验证同源音频指纹/频谱细节证据，再用局部对齐得到时间映射；候选需要独立验证和拒识。连续小幅变调、音高滑动、独立变速与变调、变调但保留共振峰，也不能归结为简单的 chroma 整数移位保证。

## Sync Toolbox 的位置

官方 [Sync Toolbox](https://github.com/groupmm/synctoolbox) 提供多尺度 DTW、限制内存的 MrMsDTW，以及 chroma/onset 结合的高分辨率音乐同步；例子以同一作品的不同录音或录音与乐谱对齐为主。代码为 MIT，数据文件明确不随代码使用同一授权。[LICENCE](https://github.com/groupmm/synctoolbox/blob/master/LICENCE)

已读取 [`mrmsdtw.py`](https://github.com/groupmm/synctoolbox/blob/master/synctoolbox/dtw/mrmsdtw.py)：`sync_via_mrmsdtw_with_anchors` 接受时间锚点；锚点要求单调增加。算法在由粗到细的限制区域中对齐，可使用 onset 特征精修。

**建议：** 将其用作已配对片段内的参考同步器/回归基线。多个重新排序的片段应分别调用，不将跨片段的相互交叉关系传为一组全局锚点。它不是已证实的任意剪辑重排检测器；也不把针对西方音乐的声明外推到语音准确率。

## Sonic Lineup / MATCH 核查

[Sonic Lineup 官方介绍](https://www.sonicvisualiser.org/sonic-lineup/)明确面向同一素材、不同演奏、不同 take、以及整体结构相近的翻唱。它是快速只读视觉比较工具，不能直接视为 CrossDiff 所需的任意剪辑 diff 引擎。其时间关联与切换试听思路可以借鉴，但与用户要求的自定义参数、持久化区域、精确测量并不等价。[官方手册](https://sonicvisualiser.org/sonic-lineup/doc/reference/1.0.1/en/index.html)

许可核实不只依据 GitHub 的自动标签：Sonic Lineup [官方下载页](https://www.sonicvisualiser.org/sonic-lineup/download.html)声明 **GPL v2 or later**；QMUL [MATCH Vamp 官方仓库](https://github.com/c4dm/match-vamp)提供 C++ 插件。已读取 [`src/Matcher.cpp`](https://github.com/c4dm/match-vamp/blob/master/src/Matcher.cpp)和 `Finder.cpp` 的许可头，明确为 **GPL-2.0-or-later**。如实际集成，需固定版本并继续核查所用子模块、依赖和完整分发材料，而非仅保存一条顶层许可名称。

**建议：** MATCH 可作为结构相近录音的现成 C++ 对齐候选；应先用本项目剪辑、重复、重排语料验证，不能从工具名或作者权威性推导出全部需求已覆盖。

## 两个文件的计算成本

以下为根据矩阵维度计算的内存量，**不是实测性能**。设双方时长相同、特征率为 `r`、各有 `N=r×时长` 帧。稠密相似矩阵有 `N²` 个单元；FMP 参考局部 DP 逐单元计算并另外保存累计矩阵，时间/矩阵内存均随双方帧数乘积增长。特征相似度还有向量维数的成本。

| 每侧时长 | 特征率 | 单矩阵单元数 | 单个 Float32 矩阵 | 两个 Float64 矩阵 |
| --- | ---: | ---: | ---: | ---: |
| 5 分钟 | 10 Hz | 900 万 | 36 MB | 144 MB |
| 1 小时 | 10 Hz | 12.96 亿 | 5.184 GB | 20.736 GB |
| 1 小时 | 2 Hz | 5,184 万 | 207.36 MB | 829.44 MB |
| 1 小时 | 50 Hz | 324 亿 | 129.6 GB | 518.4 GB |

十进制 MB/GB；尚未计入音频、特征、回溯、临时矩阵及运行时。仅计算最佳分数可以降低存储，但要回溯和保留多候选仍需额外方案。多种变速/变调假设还会增加计算量。因此短音频原型可以直接做交叉相似矩阵；生产系统不能无条件把长音频高分辨率全矩阵装进内存。

建议流程：稀疏锚点/低分辨率候选发现 → 多个局部候选 → 各自精修和验证 → 允许重排/一对多的片段关系图。全局相似图作为可展开的低分辨率解释视图；用户缩放后只细化对应局部，不把屏幕绘制分辨率等同于识别分辨率。粗到细并非绝对保证：低分辨率漏掉的短片段不会自动恢复，需要短片段候选或重叠窗口补充。

## 落地前应验证

1. 音乐、语音分开建评测，保留未改动对照，以及音高不同、内容相似但不同来源的负样本。
2. 剪切、拼接、乱序、重复、交叉淡化、音量/EQ/压缩、有损转码分别测；加入静音、持续纯音、重复背景噪声等易误匹配样本。
3. 分开测普通重采样式变速（音高联动）、保调变速、独立变调与二者叠加。局部变化和变化交界另测，不能只有整段恒定变换。
4. 统计片段检出率、错误匹配率、起止误差、变速/变调估计误差及内存/耗时。重复来源允许多解，不能用单一“唯一真值”误罚合理一对多结果。
5. 未通过这些实验前，结果使用“候选对应”“未找到可靠对应”“区域未分析”等词；不要把未匹配自动解释为确定新增/删除，也不要给未校准的百分数冠名“置信度”。

本笔记未作准确率承诺，也未将任何官方样例音频复制到项目。选定库、固定提交和执行上述基准后，才能决定首版公开支持范围。

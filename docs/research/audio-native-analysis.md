# 音频对比：macOS 原生分析与试听基础层

调研日期：2026-10-02。本文是设计研究，不表示当前应用已经支持音频。目标包括音乐与语音，优先比较同一录音经裁剪、重排、变速或变调后的版本；所有调整仅用于非破坏性对齐和试听。

## 结论

**解码、波形、正确标定的 STFT、局部试听和独立变速／变调，都有适合原生 Mac 应用的成熟基础。** 推荐 Apple AVFoundation／AVFAudio + Accelerate，CrossDiff 负责分块调度、统一标尺、来源时间映射和可取消缓存。自动找到剪辑后对应关系是另一个算法层，不能用播放器的变速功能替代。

“只比较两个文件”减少检索库规模，却不会消除长音频、片段重复、一对多对应和任意重排的问题。原生基础层应保留原始时间轴；自动算法返回片段关系后，界面可跳转和试听，而不是先把整段音频强行拉成一一对应。

## 1. 采用哪些现成接口

| 能力 | 建议实现 | CrossDiff 仍要负责 |
| --- | --- | --- |
| 解码、元信息、局部读取 | `AVAudioFile` → `AVAudioPCMBuffer`；需要多轨容器时再用 `AVAssetReader` | 文件授权、类型识别、损坏文件错误、声道布局、输入变化检测 |
| 转换分析采样率 | `AVAudioConverter` 的输入回调转换接口 | 连续块状态、转换尾部、源帧与分析帧映射、共同声道策略 |
| 波形缩略图、峰值、RMS | Accelerate／vDSP 向量统计 | 每声道多尺度桶、视口数据选择、纵轴、时间戳 |
| FFT 与窗函数 | Accelerate／vDSP FFT／DFT、窗函数与向量运算 | STFT 分帧／重叠、单边谱与窗口归一化、图块缓存、显示范围 |
| 选区、循环与 A/B 播放 | `AVAudioEngine` + 两条 `AVAudioPlayerNode` 通路 | 同一时钟调度、选区来源定位、切换淡入淡出、设备变化 |
| 独立变速、变调试听 | 每侧独立 `AVAudioUnitTimePitch` | 参数范围、变换范围、前滚／延迟、对齐播放光标 |
| 离线渲染试听片段 | `AVAudioEngine` offline manual rendering | 项目／应用缓存、取消、有限重试、图与声音的来源标识 |
| LUFS、LRA、true peak | 经测试的 `libebur128`，而非自行写测量器 | 引入固定版本、声道映射、测量范围与测试验证 |

Apple 提供格式转换、采样率转换及声道映射接口；其中简便的 `convert(to:from:)` **不能承担采样率或编解码转换**，需要使用输入回调形式。[AVAudioConverter](https://developer.apple.com/documentation/avfaudio/avaudioconverter)

`AVAudioFile` 区分文件格式与处理格式，支持按 `framePosition` 定位、按帧数读入 PCM 缓冲区；不能按压缩文件字节偏移推算播放时间。[AVAudioFile](https://developer.apple.com/documentation/avfaudio/avaudiofile)

`AVAudioUnitTimePitch` 的 rate 与 pitch 相互独立。当前 SDK 声明 rate 为 1/32～32，pitch 为 ±2400 cents，overlap 为 3～32、默认 8。这是 API 允许范围，不是跨全范围的听感质量保证。产品先给保守、清楚标注的范围，并用语音、鼓点、和弦、立体声素材试听验收。[AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch)、[overlap](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch/overlap)

Apple 已提供离线处理示例，音频引擎可以不连接输出设备而由应用主动渲染。这适合选区变换后的短缓存，不应每次拖动都渲染两个完整文件。[Performing offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)

### 备选时间伸缩库

- **Rubber Band**：作者提供 C++／C API，支持独立 tempo／pitch、实时与离线处理；GPL 开源，同时提供商业许可。可作为 Apple 算法试听质量不足时的候选，固定版本并审查实际依赖的许可证。不需要首版同时引入两套引擎。[作者官网](https://breakfastquay.com/rubberband/)、[C API 与许可证声明](https://breakfastquay.com/rubberband/code-doc/rubberband-c_8h_source.html)
- **Signalsmith Stretch**：作者的 C++11 库，MIT；有实时参数与输入／输出延迟说明。可做质量／性能对照，不能因接入简单就假定对每种素材最好。[作者文档](https://signalsmith-audio.co.uk/code/stretch/)

## 2. 图谱怎样既专业又不误导

以下是基于上述接口的产品与工程建议，不是 Apple 已提供的整套音频 diff API。

### 波形

每声道保存多尺度 `min/max` 包络，并可叠加 RMS。缩小时仍保留短瞬态；放大到采样级再显示真实 PCM 点。默认两侧同一振幅标尺，不分别拉满高度，不静默归一化原文件。立体声可折叠，但默认不要把两个声道相加后才画波形——反相内容可能被抵消。

**波形缩略桶不是新的采样信号，不能拿 min/max 或 RMS 包络计算 FFT。** STFT 和指纹必须从 PCM 或按明示参数重采样的 PCM 取得输入；不同用途的缓存分开。

### STFT 时频图与平均频谱

首版推荐默认 Hann 窗、FFT 2048 点、hop 512 点，参数可以展开调整。这是待基准验证的产品默认值，不是“专业音频统一标准”。在 48 kHz 下窗长约 42.7 ms，步长约 10.7 ms，频率格点间距约 23.4 Hz。较长窗口提高频率分辨能力而降低瞬态时间定位能力；零填充只加密格点，不凭空增加可分辨细节。

双侧必须共用窗函数、分析采样率、FFT 长度、hop、频率轴和颜色范围。显示线性／对数 Hz 时，两侧同样变换；低采样率源超过自身 Nyquist 的区域明确为空，不画成“没有高频声音”。整体平均频谱先在适当的线性功率域聚合，再转 dB，不能简单平均彩色像素或对数值。

区分三种量：样本峰值／RMS（dBFS）、标定的幅度谱、功率谱密度。幅度用 `20 log10`，功率用 `10 log10`；窗口幅度增益和窗口能量是不同的归一化。DC 与 Nyquist 不能按普通单边频率点重复加倍。定义并显示参考量，不能只写含糊的“dB”。静音显示下限而非产生 NaN；浮点 PCM 超过满幅时保留其事实，不先裁到 ±1。

vDSP 的 real FFT 具有专门的打包布局及缩放约定，必须按所选 API 文档实现，不能把教科书公式直接套到 API 返回数组。[Apple Fourier transforms 指南](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/UsingFourierTransforms/UsingFourierTransforms.html)

**特别注意：Apple《Visualizing sound as an audio spectrogram》示例使用的是 DCT，而不是 STFT。** 它适合参考 AVFoundation → vDSP → vImage 的数据流、Hann 窗和图像渲染，不能直接复制后标成 STFT。[Apple 谱图示例](https://developer.apple.com/documentation/accelerate/visualizing-sound-as-an-audio-spectrogram?changes=__5)

显示与自动匹配各有分析配置。专业图谱可保留较高采样率；指纹／局部对齐可以采用算法要求的低采样率和特征步长，但返回结果必须映射回原始秒数。不要把匹配特征的低分辨率误当完整音质分析。

## 3. 手动对齐与试听

建议每组比较区域存储：左右源区间、左右锚点、速度比、音高偏移、联动开关。先支持每组选区内恒定速度和音高；区域以外的原始素材不受影响。多锚点、区域内连续变速属于更复杂的时间映射，另行验证。保存的是比较状态，不导出或覆盖源音频。

必须明确区分“移动视图／缩放时间轴”与“变换试听”：前者不改变声音；后者在传输栏持续显示参数。原始试听、对齐试听和图谱来源要一致且可辨。默认图谱表示原始文件；如果用户看变换后的谱图，须离线渲染该预览并显式切换标记，不能一边播放变调音频一边让用户误以为图谱也已变调。

A/B 用同一 `AVAudioEngine` 时钟安排两条链路，按共同比较时间映射到各自源区间；切换时短淡入淡出，避免点击声。变速器的处理延迟、前滚、重采样延迟和输出设备延迟都要考虑，不能仅让两个 `play()` 连续执行。没有对应片段的区域显示“无对应”，不凭空拉伸另一边填满。[AVAudioPlayerNode 调度与时间转换](https://developer.apple.com/documentation/avfaudio/avaudioplayernode?changes=_6)

默认原始音量。可选“响度匹配试听”只调整播放增益，并显示实际增益与测量区间；不改原始分析统计。比较短片段时，完整文件的平均响度不一定代表当前片段，应允许基于选区测量。极短、静音或无法通过门限的片段应显示无法可靠匹配，不给无穷大增益。

**RMS 不是 LUFS，样本峰值不是真峰值。** 使用 `libebur128` 实现感知响度、LRA 和 true peak，并对照 EBU 测试信号；不自写 K-weighting／门限算法后直接宣称符合标准。避免偷偷限幅，因为限幅会改变待比较内容；需要留输出余量时同时降低两侧试听增益，并清楚显示。[ITU-R BS.1770-5](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I%21%21PDF-E.pdf)、[libebur128 官方源码](https://github.com/jiixyj/libebur128)、[EBU Tech 3341](https://tech.ebu.ch/publications/tech3341)、[EBU 测试集](https://tech.ebu.ch/publications/ebu_loudness_test_set)

## 4. 大文件、格式与本机探测

以 Float32 双声道 48 kHz 为例，一小时解码数据约 1.38 GB；两侧约 2.76 GB，还未计算 STFT 与 UI。不能把两个文件一次性装入数组。建议：

1. 持续分块解码，复用固定容量缓冲；帧索引用 64 位，长度换算做溢出检查。
2. 先生成全局波形粗览，再后台细化；谱图仅为可见区及少量前后区间生成图块。
3. 使用有界内存 LRU 与磁盘缓存；缓存键包含源文件身份／修改状态、采样率、声道策略、窗口和算法版本。
4. 任务批次间检查取消；参数变化后旧结果不能覆盖新结果。图块与候选片段均返回清楚的完成／部分完成状态。
5. 音频回调不做磁盘读写、分配大数组、等待锁、调用 SwiftUI 或运行比较算法；分析在后台，绘制和状态更新在主线程。
6. 分析失败与格式不支持分别显示。损坏输入、过多声道、非常长文件、变化中的来源都需有明确限制，不能悄悄截断后返回“相同”。

容器扩展名不等于编码能力；WAV 也可能装不同编码，M4A 可能是 AAC／ALAC，系统版本会影响实际支持。首版可把 WAV、AIFF、FLAC、MP3、M4A 作为目标导入集，但应以 `AVAudioFile` 实际打开及解码结果为准，不能从一个扩展名白名单承诺所有变体。

本次只做无播放、无原生窗口的项目内能力探测：macOS 26.6.2，本机生成 1 秒、48 kHz、16-bit 双声道合成音频，通过 `AVAudioFile` 转为 Float32，以 1024 帧分块读完，再 seek 到第 1000 帧并读取 256 帧；**WAV 与 AIFF 均成功**。`afconvert -hf` 能列出 FLAC、MP3、M4A 等容器，但本环境的压缩编码夹具生成未成功，因此未验证这些格式的实际解码，不能据此判断为“已支持”或“macOS 不支持”。还须在项目最低 macOS 14 上验证。

探测代码与自生成数据位于忽略目录 `.build/research-audio-native/`，未安装依赖、未播放声音、未修改应用源码或用户音频。最初探测在到达文件末尾后继续调用读取得到错误；修订后根据可用长度限制每次读取，完成上述完整读取／定位检查。实现时仍需处理解码器提前 EOF、异常长度及短读。

## 5. 插件框架要怎样接

当前 [PluginProtocol.swift](../../Sources/CrossDiffCore/PluginProtocol.swift) 没有音频输入或音频结果视图；[PluginRunner.swift](../../Sources/CrossDiff/PluginRunner.swift) 为 JSON 请求／结果，默认 15 秒、上限 60 秒，输入 envelope 最多 32 MiB、输出最多 8 MiB。受限 JavaScript helper 没有文件系统、网络、原生样本句柄或动态载入库能力。[现有插件规范](../plugins/development.md#6-运行边界)

因此建议沿用摄影插件的边界：

- **宿主音频能力**负责经过用户选择的来源、Apple 解码／统计、固定原生算法、图块与试听。耗时任务由可取消后台作业管理。
- **受限插件**接收有界元信息、特征摘要或候选片段，进行有界关系处理，返回片段映射、分数、局限说明与展示建议；宿主校验时间范围、单调性约束（若适用）、输入版本与预算。
- **原生视图**消费宿主缓存，不把数小时 PCM、完整谱图或完整两两相似度矩阵序列化成 JSON。不把宿主文件路径当作任意插件的读取授权。

摄影模式能承载首个官方音频插件，但它不意味着第三方可自由下载 Python／Java／C++ 算法后在受限 JS 内使用。若要让第三方实现完整音频引擎，后续需要独立设计受约束的流式分析服务／句柄协议及分发模式；当前“完全信任可执行文件”拥有广泛本机权限，不能为了接某个库而静默切换，更不能标成安全沙箱。

## 6. 实现前应锁定的验证

- PCM 数值基准：同频不同相位正弦、非整周期正弦、冲激、静音、白噪声、反相双声道；分别验证峰值、RMS、FFT 频点、窗缩放与左右同尺度。
- 图谱连续性：块边界与 STFT 帧重叠、零填充、最后不足一帧、不同采样率相同频率、不同窗长的可解释差异。
- 试听：同源 A/B 切换不漂移，选区定位正确；开启 rate／pitch 后映射光标准确，恢复原始参数后原文件散列不变。
- 响度：接入固定版本 `libebur128` 后运行 EBU 测试；未验证前不显示 LUFS／true peak 已符合标准的承诺。
- 系统：最低 macOS、设备切换／暂停恢复、超长文件与取消、内存／缓存预算、插件禁用时终止旧作业。

首轮技术验证应把“数字正确”和“试听自然”分开验收。FFT 峰值对了不代表变速器音质已经合格；两张谱图相近也不构成音频相同的证明。

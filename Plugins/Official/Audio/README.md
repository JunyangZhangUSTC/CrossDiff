# Audio Compare / 音频对比

官方只读音频比较插件。原生宿主负责 Apple 音频解码、波形、STFT、选区、试听及受控的本地识别；受限 JavaScript 仅整理有界元数据和识别证据，不读取文件、不联网、不生成指纹。

The official read-only audio comparison plugin. Native host services handle Apple audio decoding, waveforms, STFT, regions, audition and controlled local recognition. Restricted JavaScript only compares bounded metadata and summarizes supplied evidence; it has no file access, network access or fingerprinting implementation.

- 插件标识 / Plugin ID: `org.crossdiff.audio`
- 协议 / Input and view: `audioAnalysis` → `audioTimeline`
- 结果 / Result schema: `crossdiff.audio/1`
- 两方比较 / Pairwise comparison only
- 候选上限 / Correspondence budget: 512

音频格式最终以当前 macOS 解码结果为准。文件扩展名用于入口筛选，不构成对所有编码或损坏输入的兼容性承诺。

Format support depends on the current macOS decoder. Extensions select the comparison view and do not promise support for every codec or damaged input.

分析每侧最多 8 声道；试听仅支持单声道和立体声。3–8 声道文件仍可查看波形、频谱并查找对应片段，不能直接试听。

Analysis supports up to eight channels per side; audition supports only mono and stereo. Three-to-eight-channel files can still display waveforms and spectra and find corresponding segments, without audition.

对应片段保留双方原始秒区间、原始证据分数、方法与状态，允许重排和一对多。覆盖时长按两侧区间并集独立计算。未知音高不填写估计；原始证据分数不是概率。未找到对应不能视为确定删除。所有变速和变调仅用于试听，不修改输入文件。

Correspondences retain original time ranges, raw evidence scores, method and state; reordered and repeated segments are permitted. Coverage counts the union of ranges independently on each side. Unknown pitch remains unavailable, raw scores are not probabilities, and unmatched ranges are not confirmed deletions. Rate and pitch audition never modify source files.

默认参数与识别范围须结合宿主版本。设计与算法研究见 [音频设计提案](../../../docs/architecture/audio-comparison.md)。插件随项目使用 GNU AGPL v3；原生识别依赖的许可随宿主另行分发。

Defaults and recognition capabilities depend on the host version. See the [audio design proposal](../../../docs/architecture/audio-comparison.md). This plugin follows the project's GNU AGPL v3 license; native recognition dependencies retain their separately distributed licenses.

# 摄影对比增强：单通道、合并直方图与专业指标

调研及来源访问日期：2026-10-04。本文保留实现前的设计研究与候选方向，不代表全部已实现。后续 0.13.1 摄影分支选择了 Lab L* 感知明度，加入通道预览、比较直方图和拍摄参数对照；当前范围见[实现设计](../architecture/photography-comparison.md)。专业数值处理交给 Apple 框架或成熟权威库，CrossDiff 负责组合、状态、图表和解释。相关背景见[依赖选型](photography-library-selection.md)、[RAW 与色彩边界](photography-raw-and-color.md)。

## 已核实的来源事实

### 1. 单通道、灰度与亮度不是同一种数据

OpenCV `extractChannel` / `mixChannels` 可抽取或重新排列通道；`COLOR_GRAY2RGB` 把同一数值复制到 RGB 三通道。相反，`COLOR_RGB2GRAY` 是三通道的加权组合，并不是 R、G、B 中任意单个通道。[OpenCV 数组操作](https://docs.opencv.org/4.12.0/d2/de8/group__core__array.html)、[OpenCV 颜色转换定义](https://docs.opencv.org/4.12.0/de/d25/imgproc_color_conversions.html)

同一文档中，`COLOR_RGB2GRAY` 及 RGB→YCrCb 使用 0.299/0.587/0.114 系数；RGB→XYZ 使用 Rec.709 原色、D65 白点定义。不能因为 API 名字出现 Y 或 Gray，就把输出标作 Rec.709 luma 或物理亮度。`COLOR_RGB2XYZ` 的矩阵转换也不代替输入的线性化与 ICC 色彩管理。[OpenCV 颜色转换定义](https://docs.opencv.org/4.12.0/de/d25/imgproc_color_conversions.html)

ICC 的 sRGB 说明分别定义线性 RGB 与经分段传递函数编码的 sRGB 数字值；线性量与显示编码值不能共用一个未注明含义的“亮度”标签。HSL L 是色彩模型中的明度，也不等于 XYZ Y。[ICC sRGB 说明](https://registry.color.org/rgb-registry/files/sRGB.pdf)、[OpenCV HLS / XYZ 定义](https://docs.opencv.org/4.12.0/de/d25/imgproc_color_conversions.html)

### 2. 不同示波器保留不同的信息

| 视图 | 官方说明能够支持的读法 | 对双图比较的启发（设计推论） |
| --- | --- | --- |
| 直方图 | 展示色调值的分布；可选 Luma、RGB Overlay、RGB Parade 或单色通道。 | 适合比较整体或所选区域的明暗、颜色占比；丢失空间位置，不能证明主体相同。 |
| 亮度波形 | 横向对应图像横向位置，纵向是所选亮度/色彩分量的级别。 | 同场景或相似构图时，能定位“哪一侧高光/阴影不同”；不同构图时只做独立读图。 |
| RGB Parade 波形 | R/G/B 三幅波形并排显示，能比较两幅画面的通道级别。 | 有助于看局部通道差异；高红通道也可能来自红色主体，不自动等于白平衡错误。 |
| 矢量示波器 | 方位表示色相，离中心的距离表示色度/饱和程度；参考标记由所用模式决定。 | 适合观察暖/冷色群、色彩方向和集中程度；不能恢复调色滑块，也不能给作品打分。 |

事实来源：[Apple 直方图显示选项](https://support.apple.com/en-gb/guide/final-cut-pro/ver761cb0f2/mac)、[Apple 波形显示选项](https://support.apple.com/en-nz/guide/final-cut-pro/ver761c9d9d/mac)、[Apple 矢量示波器显示选项](https://support.apple.com/en-ae/guide/final-cut-pro/ver761c9f95/mac)。Apple 的文档针对其视频色彩管线；将这些视图用于静态摄影，需要另外固定色彩空间和刻度，不能直接照搬 IRE、广播合法范围或 nits 标签。

### 3. 拍摄曝光、显影曝光与成片分布必须分开

ImageIO 的 EXIF 字段提供曝光时间、光圈、ISO、曝光补偿等记录；字段存在不等于图像中能推导出同一信息。`CIRAWFilter` 则有显影曝光、基线曝光、色调曲线、白平衡等处理参数，`baselineExposure` 默认值随相机设置变化。[Apple EXIF 字段](https://developer.apple.com/documentation/imageio/exif-dictionary-keys)、[Apple RAW 基线曝光](https://developer.apple.com/documentation/coreimage/cirawfilter/baselineexposure)、[Apple RAW 显影曝光](https://developer.apple.com/documentation/coreimage/cirawfilter/exposure)

Apple 的 ProRAW 官方示例把“默认外观”与“线性场景参考输出”分开：为了得到后者，需要关闭若干默认外观处理，再输出到指定线性色彩空间的浮点缓冲。仅把普通成片或默认显影图转换到线性 sRGB，并不会撤销原有色调映射，也不会还原场景辐射或传感器采样。[Apple WWDC21：Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)

据此推论：成片高亮像素比例可以描述当前渲染结果，不能证明 RAW 传感器过曝、高光不可恢复、快门错误或后期增加了多少 EV。两幅不同场景作品更不具备这种因果可比性。

### 4. 统一色彩空间和分析精度是比较的前提

Core Image 会把输入匹配到工作空间，输出时再匹配到目标空间；默认工作空间是扩展线性 sRGB。显式配置比依赖默认值更适合可重复的比较。Accelerate vImage 提供 8 位和 32 位浮点的直方图 API；OpenCV `calcHist` 提供通道、mask、区间和分箱配置，均不要求自己重写统计算法。[Apple 工作空间](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)、[Apple vImage 直方图](https://developer.apple.com/documentation/accelerate/histogram)、[OpenCV 直方图](https://docs.opencv.org/4.12.0/d6/dc7/group__imgproc__hist.html)

FFmpeg 已有 `waveform` 与 `vectorscope` 滤镜，包含分量选择、叠加/parade 等显示方式；矢量示波器的 `colorspace=601/709` 是参考刻度配置，不能当作 ICC 色彩转换。此路径可作为后续成熟库候选，尚未在本项目验证。[FFmpeg waveform](https://ffmpeg.org/ffmpeg-filters.html#waveform)、[FFmpeg vectorscope](https://ffmpeg.org/ffmpeg-filters.html#vectorscope)

## 对 CrossDiff 的产品设计建议

以下为设计建议，不是来源宣称的统一摄影标准。

### 第一阶段：直接改善对比效率

以下保留最初的交互建议；最终实现按用户偏好默认分开，点击“叠加”才合并查看，并保留已保存的布局选择。

- **两张主图保留，增加显式开启的照片通道预览：彩色 / R / G / B。** 图表的通道选择与照片预览开关分开，避免查看一条分布时主图突然变灰；照片 R/G/B 采用灰度预览，图像标题持续显示通道名，可支持两侧同步。实现用现有 OpenCV 抽取通道和复制通道，或 Apple 官方通道操作；不手写像素循环或专业色彩矩阵。它只改变预览，不改原图、选区或分析基线。
- **统计区合为一个比较面板。** 默认同坐标轴叠加左/右分布；当前通道分别画实线/虚线，标签和图例同时写“左/右”。RGB 总览可用 R/G/B 三个小图，每个小图叠两侧，避免六条仅靠颜色区分的曲线。保留并排模式便于读细节；二级视图可显示同一分箱的“右−左”占比差，单位写“百分点”，不把它当亮度值之差。
- **共轴是数值契约。** 两侧相同色彩空间、通道定义、分箱边界、横轴范围与纵轴尺度；每侧按自身有效像素数归一化为占比。不可各自按最高柱归一化后共轴叠加。对数纵轴若提供，应明确标注；切换不重算源统计。
- **主图、通道和区域联动。** 选区存在时面板清楚标注左/右区域名与样本数；用户可以比较同一主体，也可以独立框选不同作品中的天空、皮肤、阴影。不同面积的 ROI 用占比，不能比原始柱高。刷选直方图区间只高亮图中对应像素，不改变原 ROI，也不把高亮 mask 反过来作为统计输入，避免筛选后分布自我改变。
- **紧邻数值显示分析模式。** 默认维持“sRGB · SDR 显示编码”的解释，HSL 写“明度 L”。将线性亮度作为独立指标，不把现有 HSL L 改名为“曝光”。

### 第二阶段：增加可解释的数值，而非综合评分

| 建议指标 | 数值与依赖路径 | 能说明什么 / 不能说明什么 |
| --- | --- | --- |
| 当前渲染相对亮度 Y：均值、P10/P50/P90 | Apple 色彩管理输出线性 sRGB 浮点；OpenCV `COLOR_RGB2XYZ` 后抽取 Y，统计走成熟库。分位数若由直方图估算，注明分箱误差。 | 描述所选区域的渲染亮度分布；不是现场照度、nits 或拍摄 EV。 |
| 色调跨度 | 显示同一定义下 P90−P10，名称写“色调跨度”；也可直接显示三个分位点。 | 比单个均值更能说明阴影和高光分布；不称相机动态范围，不采用 max/min 求“可用动态范围”。 |
| SDR 端点占比 | 在固定 SDR 基线下统计 R/G/B 各自端点、任一通道端点和全通道端点；阈值和分母明确。 | “达到 SDR 白端点”与“接近白端点”分开；这是当前渲染的端点统计，不是传感器剪切判断。 |
| 色彩分布 | 继续复用 OpenCV HLS，显示彩色像素的色相占比、饱和度分位与单独的中性像素占比；保留中性判定阈值。 | 暖色占比不等于色温；平均色相容易跨 0/360° 失真，不以普通算术均值报告。 |
| 阴影/中调/高光色彩分布 | 在明确的亮度定义和固定分组阈值下，调用 OpenCV mask 与直方图统计；显示各组样本量。 | 说明各色调区域的颜色构成；分组阈值是产品定义，不称现场色温或通用曝光标准。 |
| EXIF 并列表 | 只显示文件实际记录的快门、光圈、ISO、曝光补偿、镜头等，附来源；缺失写“未记录”。 | 是拍摄记录，不与像素差值混作同一单位；不从照片估计缺失参数。 |

不要把 sRGB 编码数值比值直接转成“曝光差 EV”。即使基于正的线性 Y 做 log2 比值，也只表示指定区域、指定渲染基线下的亮度比；在任意两张照片之间默认展示一个 EV 数字会诱导因果误读，建议暂不提供。

Lab L* 可作为感知明度候选，与相对亮度 Y 分开命名，默认展示哪一个需在实现前选定和验证；不把 L* 标成线性亮度。文件确实记录的 XMP 曝光、白平衡、HSL 设置可沿用现有元数据读取方向，逐项注明来源、处理版本与缺失状态；其具体字段覆盖仍按已有研究和样本验收，不从像素反推。

Lab / ΔE 可以用于同源、已配准或已选定对应色块的后续专门比较；需要注明转换白点、参考条件、色差公式和统计范围，复用权威实现并验收。不同场景的全图平均 ΔE、质量分、白平衡正确度或“距大师风格分数”没有足够解释依据，不列入这一阶段。

### 剪切必须在正确的数据层定义

1. **源编码端点**：源文件某通道已经位于其编码范围端点。端点本身仍可能来自纯色、图形或渲染选择；不能直接认定拍摄错误。
2. **分析转换越界**：在转换成指定分析空间后、任何 clamp 之前，出现负值或超过 SDR 白点。记录为该空间的越界量；HDR 超过 1.0 不自动属于错误。
3. **当前 SDR 渲染端点**：映射或截断后的端点占比。它可能混合原有端点与转换新增的端点，若只拿到此层，必须用该名称。
4. **传感器/RAW 剪切**：需要对应传感器域、黑白电平及通道语义，不能由默认显影成片代替。当前研究不承诺此能力。

应在 clamp 前后分开采集诊断，避免把 P3/HDR→sRGB 过程中产生的端点归因于原图曝光；透明像素、无穷/NaN、无颜色配置时的假设都要采用两侧相同且可见的规则。

### 第三阶段：示波器按用途逐步引入

优先亮度波形，其次 RGB Parade，最后矢量示波器。波形适合左右并排、纵轴共享；默认叠在一张波形上会混淆两张照片各自的横向位置。矢量图可左右分图或切换叠加，参考轴和密度归一化必须相同。HSL 极坐标色相/饱和度图若先行实现，应准确命名，不能冒充有视频标准刻度的矢量示波器。

调用 FFmpeg scopes 是可验证的候选；正式纳入前需固定版本、像素格式、位深、色彩原色/传递函数、全范围/有限范围、进入滤镜的转换路径、许可证和 macOS 打包方式。没有核实成熟实现时宁可标为后续，不用自写矩阵和示波器算法填补功能空白。

## 当前代码与实施约束

本轮只读检查显示：[PhotoAnalysisEngine.swift](../../Sources/CrossDiff/PhotoAnalysisEngine.swift) 已用 Apple 图像管线和 RGBA 浮点渲染，分析标识为 sRGB SDR；[PhotoCVBridge.cpp](../../Sources/PhotoCVBridge/PhotoCVBridge.cpp) 使用 OpenCV 4.12.0，把 RGB 限制到 0…1 后计算 HLS 与直方图，并明确注释这不是 RAW 剪切检测。因此第一阶段可复用现有分布；第二阶段的线性 Y 与转换前越界需要独立、明确的数据路径，不能从现有被截断的 HLS 输出反推。

面向不同场景作品，只说“这幅图当前区域更亮/暖色像素更多/高端数值更集中”；只有用户明确建立同源或对应区域，才比较对应像素。示波器读图必须结合照片内容，不提供“正确曝光”“正确肤色”“作者参数”或审美优劣的自动结论。

## 后续验收建议与本轮验证

后续实现应使用已知色块、灰阶、纯 R/G/B、透明与非有限样本、相同颜色不同 ICC 编码、不同面积 ROI、HDR 超范围样本和真实 RAW 验证：单通道语义、两侧共同刻度、有效像素分母、端点纳入、采样误差和旧任务取消。下采样会消除小高光或细噪点，采样端点统计须标估计，不能宣称全分辨率剪切检测。

本研究阶段仅完成一手资料核查、代码只读核查与文档链接检查；未构建应用、未执行 RAW 解码、示波器性能或界面验收。后续实现验证单独记录于[验收目录](../validation/README.md)。

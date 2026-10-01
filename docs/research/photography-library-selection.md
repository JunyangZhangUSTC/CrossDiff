# 摄影分析依赖选型：HSL、曲线与示波器

调研日期：2026-10-02。状态：实现前的依赖候选调研记录。0.9.0 实际采用 Apple 图像管线与 OpenCV 4.12.0 的 HLS 转换、直方图，详见[实现规格](../architecture/photography-comparison.md)；其余候选不表示已实现。用户约束：专业底层算法采用 Apple 官方框架或成熟、权威的开源库；CrossDiff 负责集成、原生展示和交互，不另写 RAW、色彩转换或专业诊断算法。只对比，不修改照片。

## 推荐组合与边界

| 能力 | 推荐实现来源 | 真实 API / 入口 | 能力边界 |
| --- | --- | --- | --- |
| 色彩管理及原生图像管线 | Apple Core Image / Image I/O | `CIContext` 的 `workingColorSpace`；`CGImageSource` | 先明确输入、工作及显示空间，再调用统计库。配置和解码能力不能由 HSL 函数代替。 |
| RGB 区域直方图 | Apple Core Image 优先 | `CIFilter.areaHistogram()` / `CIAreaHistogram` 的 `inputImage`、`extent`、`count`、`scale` | 这是现成统计能力；仍需声明分析范围、刻度、颜色空间。不能把线性值与显示编码值的直方图混为一谈。 |
| HSL 像素值与分布 | OpenCV `core` / `imgproc` | `cv::cvtColor(..., cv::COLOR_RGB2HLS)`；`cv::calcHist(...)` | 计算当前像素的 HSL 分布，不读取或推断修图软件的 HSL 滑块值。 |
| 动态 ROI 统计与联动 | 库的 ROI / mask 配合原生控件 | OpenCV `Mat` ROI、`calcHist` 的 `mask` 参数；Core Image 区域统计的 `extent` | CrossDiff 管理选区与显示，统计由库执行；图表反向高亮沿用同一通道和区间定义。 |
| 已记录的曲线与 HSL 设置 | Apple Image I/O 优先，按 Adobe 官方字段资料识别 | `CGImageMetadataCreateFromXMPData`、`CGImageMetadataCopyTagWithPath`、`CGImageMetadataEnumerateTagsUsingBlock` | 只显示实际存在的元数据。需区分图片内嵌记录、配套 `.xmp` 与用户另选的预设。 |
| 复杂 XMP 文件支持 | Adobe XMP Toolkit SDK，候选补充 | `SXMPFiles` / `SXMPMeta` 的 `GetProperty`、`CountArrayItems`、`GetArrayItem` | 元数据解析器，不是 RAW 显影器或曲线恢复引擎；首版不必为了普通 XMP 强行引入。 |
| 波形 / RGB Parade / 矢量示波器 | FFmpeg `libavfilter`，后续候选 | `waveform`、`vectorscope` 过滤器 | 已有成熟实现，但需单独验证静态摄影的颜色管线与格式精度；不默认视为即插即用。 |

Apple 官方入口：[工作色彩空间](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)、[区域直方图](https://developer.apple.com/documentation/coreimage/ciareahistogram)、[XMP 元数据](https://developer.apple.com/documentation/imageio/cgimagemetadata)。

## HSL 怎样获得

**已核验事实：** OpenCV 提供 RGB/BGR→HLS 转换。这里 HLS 与常说的 HSL 描述相同三个分量，但输出通道顺序为 **H、L、S**；不能拿 HSV 的 V 冒充 L。标准 `COLOR_RGB2HLS` 支持 8U 和 32F，32F 输入 RGB 约定在 0…1；输出 H 以角度表示，L/S 在 0…1。标准 8U 的 H 采用约半角编码；`*_FULL` 另有范围，不能混用。16 位源图应先按明确定义转浮点，而不是直接调用不支持的 16U HLS 转换。[OpenCV 转换 API](https://docs.opencv.org/4.13.0/d8/d01/group__imgproc__color__conversions.html)、[转换定义](https://docs.opencv.org/4.13.0/de/d25/imgproc_color_conversions.html)

**建议集成：** 用 Apple 管线生成明确的、统一编码 RGB 浮点分析输入；HSL 首版限定为注明规则的 SDR 表达。不要把 RAW 传感器数组、未声明配置的 P3 RGB、线性 RGB 和普通 sRGB 成片直接混着送入同一个 HLS 流程。HDR/超范围值需另外确定分析表达，不能先悄悄截断再宣称精确。

`cv::calcHist` 可按选定通道计算一维或多维分布，支持同尺寸的 8 位 mask。H/S 二维分布在 HLS 数组中选择通道 **0、2**，不是常见 HSV 示例中的 0、1。直方图区间上界不包含在内，必须明确处理 L/S 等于 1 的端点，避免漏掉纯白或满饱和像素。[OpenCV 直方图 API](https://docs.opencv.org/4.13.0/d6/dc7/group__imgproc__hist.html)

**产品解释：** 用户看到的是“选中区域包含哪些颜色、各占多少、明暗如何”，不是“原作者红色色相滑块调了多少”。低饱和中性色应单列，分布图两侧共享刻度；这些属于已公开定义的统计呈现规则，不是另造摄影评价算法。

## 曲线必须区分三件事

1. **图片分布曲线**：直方图或累计分布是当前像素的统计结果；可以显示，但应使用这个名称。
2. **文件记录的编辑曲线**：本方案读取 XMP 中确实存在的对应设置，其他编辑记录格式需另行支持；没有记录就显示“未记录”，不画一条虚假的线性曲线代替。
3. **应用曲线的处理函数**：Apple `CIFilter.toneCurve()` 接收控制点并修改图像，属于前向处理；它不会从照片读取或恢复作者曲线。当前用户不需要修图，因此不以这个 API 实现所谓“曲线解析”。[Apple 曲线滤镜](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/tonecurve%28%29)

**已核验事实：** Adobe 的 Camera Raw namespace 为 `http://ns.adobe.com/camera-raw-settings/1.0/`，正式页面列出 `crs:ToneCurve`；Adobe 官方样例另外包含 `ToneCurvePV2012` 及 RGB 分通道的有序点数组，以及 `HueAdjustmentRed` 等字段。[Adobe Camera Raw namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)、[Adobe 现代 XMP 样例](https://github.com/AdobeDocs/cis-photoshop-api-docs/blob/main/sample-code/lr-sample-app/crs.xml)

**建议：** 首版用 Apple XMP 解析读取记录，展示曲线控制点与原始数值；如连接点只用于辅助读图，应标明是示意，不保证重现原编辑器的插值或渲染。字段含义、处理版本与启用状态一起展示。官方样例不是所有版本完整稳定的 schema，不据此承诺所有 RAW 或导出图片一定附带这些字段。

如果 Apple 对实际目标文件的读取覆盖不足，Adobe SDK 的通用属性与数组 API 可读这些确实存在的字段；`GetProperty` 返回存在性，`GetArrayItem` 使用 1 起始索引。SDK 能读出记录，并不证明记录完整、当前启用、与导出像素一致，更不包含完整显影过程。[Adobe SDK 指南](https://raw.githubusercontent.com/adobe/XMP-Toolkit-SDK/main/docs/XMPProgrammersGuide.pdf)、[官方仓库](https://github.com/adobe/XMP-Toolkit-SDK)

**明确不做：** 从两张成片“还原大师曲线”、通过直方图匹配声称得到作者原配方、把 HSL 统计当成编辑器参数、复制开源修图软件的一部分公式后自建一套未验证显影引擎。

## FFmpeg 只作为示波器候选

**已核验事实：** `waveform` 提供色彩分量波形、叠加与 parade 排列；`vectorscope` 将两个指定分量绘成二维图。后者的 `colorspace=601/709` 是绘制参考刻度的选项，不是替摄影输入执行 ICC 色彩管理的开关。[FFmpeg 官方过滤器文档](https://ffmpeg.org/ffmpeg-filters.html#waveform)、[vectorscope](https://ffmpeg.org/ffmpeg-filters.html#vectorscope)

**建议：** 可把静态照片作为单帧交给成熟过滤器，但正式采用前要固定像素格式、位深、全/有限范围、传递函数、色彩矩阵及进入过滤器前的色彩转换，并用已知色块核验。静态分析不得沿用跨帧峰值累积。首版无需为展示少量核心分布图立即内嵌整套 FFmpeg；尚未验证的波形/矢量图可推迟，不能为了凑功能改为手写算法。

## 依赖选择结论

优先 **Apple 管线 + OpenCV 小范围模块**；**Adobe XMP SDK** 留作真实文件覆盖不足时的补充；**FFmpeg scopes** 留作明确验收的下一层能力。原生图表绘制、选区状态和任务调度由 CrossDiff 实现，不重新实现专业底层算法。

OpenCV 4.5+ 官方采用 Apache 2.0，Adobe XMP Toolkit 采用 BSD-3-Clause；选定版本和实际构建依赖应附带其许可证与来源，不能把“开源库”理解成无需保留授权声明。[OpenCV 许可](https://opencv.org/license/)、[Adobe SDK 许可](https://github.com/adobe/XMP-Toolkit-SDK/blob/main/LICENSE)

本轮未验证：Swift/C++ 桥接、二进制体积、插件隔离、macOS 14 兼容构建、RAW/ICC/XMP 真样本和交互性能。以上是选型依据，不是已经支持的功能清单。

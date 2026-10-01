# 摄影对比：RAW、色彩与拍摄参数的可信边界

调研日期与来源访问日期：2026-10-02。状态：实现前的设计研究记录，不是完整格式支持承诺；当前实现及边界见[摄影规格](../architecture/photography-comparison.md)。本轮产品范围是只读分析与局部选区比较，不包含调色、修图或写回原图。

## 已核实的事实

### RAW 是一类文件，不是统一的扩展名

常见扩展名如下，实际相机可能同时支持多种格式。此表仅解释名称，不代表 CrossDiff 已支持这些文件。[Adobe 官方相机及文件扩展名表](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/camera-raw-plug-supported-cameras.html)

| 来源 | 常见 RAW 扩展名 |
| --- | --- |
| Canon | `.cr2`、`.cr3`，较早型号 `.crw` |
| Nikon | `.nef`、部分型号 `.nrw` |
| Sony | `.arw`，较早型号 `.srf`、`.sr2` |
| Fujifilm | `.raf` |
| Panasonic | `.rw2`，部分较早型号 `.raw` |
| Olympus / OM System | `.orf` |
| Pentax | `.pef`、`.dng` |
| Hasselblad | `.3fr`、部分工作流程 `.fff` |
| Phase One | `.iiq` |
| Sigma | 部分型号 `.x3f`，部分型号 `.dng` |
| 多家厂商与 Apple ProRAW | `.dng` |

DNG 是公开规范的 RAW 容器，规范允许私有元数据；它不意味着所有 DNG 都具有相同的数据组织和显影行为。[Adobe DNG 说明与规范入口](https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html)

### 原生解码取决于系统、机型和拍摄模式

macOS Sonoma 的 Apple 官方支持表按相机型号列举，并有“仅未压缩 RAW”“不支持 High Res Shot”“仅单张 RAW”等脚注。该归档表说明覆盖截至 2024-07-09 的 Sonoma 最新版本；不能把它当作所有 macOS 14 小版本或以后系统的统一清单。[Apple Sonoma RAW 支持表](https://support.apple.com/en-us/105094)

`CIRAWFilter.supportedCameraModels` 可查询当前系统的机型列表。每个 RAW filter 还提供 `supportedDecoderVersions` 和 `decoderVersion`。本机 SDK 头文件的只读核查确认：`CIRAWFilter` 从 macOS 12 可用，新建实例默认选择当前图像类型最新可用解码器；因此 API 可用于项目的 macOS 14 下限，但输出随解码器版本变化的风险需要记录。[Apple supportedCameraModels](https://developer.apple.com/documentation/coreimage/cirawfilter/supportedcameramodels)、[Apple decoderVersion](https://developer.apple.com/documentation/coreimage/cirawfilter/decoderversion)

LibRaw 是可选的另一条本地解码路线。其官方清单也绑定版本及构建条件：当前清单标为 0.22，声明相机支持以启用全部构建特性为前提。不能把网站上的所有机型数量直接当成应用包的能力。[LibRaw 相机清单](https://www.libraw.org/supported-cameras)

### 嵌入预览、显影图像、传感器数据必须区分

`CIRAWFilter.previewImage` 是可选辅助预览；`outputImage` 是解码及显影后的图像。Apple 明确指出默认输出具有默认显影外观，并提供曝光、白平衡、降噪、局部色调映射等参数。LibRaw 也分别提供 thumbnail 解包和 RAW 解包流程。因此读取到一张可见预览，不能证明 RAW 数据已完整解码。[Apple previewImage](https://developer.apple.com/documentation/coreimage/cirawfilter/previewimage)、[Apple RAW / HDR 处理介绍](https://developer.apple.com/videos/play/wwdc2023/10181/)、[LibRaw API notes](https://www.libraw.org/docs/API-notes.html)

设计含义：基于解码结果得到的是“此显影结果的直方图”，不是传感器原始直方图；从显影结果看到的高光截断，也不能直接证明 RAW 高光已经不可恢复。这是对数据层次的推论，不是上述 API 自动给出的判断。

### 色彩空间、位深与 HDR 会改变统计的含义

Core Image 默认把输入转换到共同工作色彩空间，渲染时再转换到输出空间；默认工作空间为扩展线性 sRGB。工作像素格式控制中间缓冲精度，输入与输出格式还会发生转换。[Apple workingColorSpace](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)、[Apple workingFormat](https://developer.apple.com/documentation/coreimage/cicontext/workingformat)

Apple 的 HDR 管线文档要求保留色彩空间和足够精度；16/32 位浮点格式可承载 HDR。EDR 数值可以超过 SDR 白点 1.0，屏幕的可显示余量会随显示器、亮度和环境变化。故不能先截成 8 位 SDR，再声称测得原图的 HDR 范围；也不能把屏幕当前显示亮度作为文件的固定分析结果。[Apple HDR 图像管线](https://developer.apple.com/videos/play/wwdc2023/10181/)、[Apple EDR 显示与 headroom](https://developer.apple.com/videos/play/wwdc2022/10114/)

### 拍摄参数应来自元数据，显影参数另行标识

ImageIO 的 EXIF 字段包括曝光时间、光圈、ISO、曝光补偿、焦距、镜头型号和白平衡模式；字段定义不保证每张图片都携带或保留这些值。尤其 `WhiteBalance` 是模式，不等同于准确的 Kelvin 数字。[Apple EXIF 字典](https://developer.apple.com/documentation/imageio/exif-dictionary-keys)、[Apple ExposureTime](https://developer.apple.com/documentation/imageio/kcgimagepropertyexifexposuretime)

`CIRAWFilter.neutralTemperature` 是解码白平衡参数，可被设置；不应直接改名为“现场色温”。[Apple neutralTemperature](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltemperature)

推论：不同快门、光圈、ISO、光照及后期处理可以产生相近成片，仅凭两张最终图片，无法唯一还原拍摄快门、光源色温或调色软件的曝光/曲线/HSL 滑块。插件可以报告“当前像素更亮、暖色区域占比更高”，不应断言“大师曝光加了 0.7 EV”或“色温设置为 6200K”。

## 面向 CrossDiff 的建议（待设计确认）

1. **先建立可解释的原生管线。** 常规位图走 ImageIO，RAW 走 `CIRAWFilter`，均在本地只读处理。加载时报告“已解码 RAW / 仅嵌入预览 / 不支持该文件”，不静默把预览当完整 RAW。按实际文件尝试解码；扩展名与机型清单用于提示，不代替成功解码验证。
2. **原图与分析区域分离。** 框选、移动、缩放选区只改变分析范围；统计直接取对应解码图像区域，不能从窗口截图、缩小显示图或拉伸后的截图取样。左右允许独立选区，适合同类主体不同构图；同一场景可另外启用联动选区。记录区域坐标与分析分辨率。
3. **显影基线要透明、稳定。** 首版建议采用可记录的 Apple 默认显影，不向用户暴露编辑滑块。显示解码器、白平衡/显影来源、色彩空间和 SDR/HDR 状态；同一会话不随意切换 RAW 解码器。不能承诺与相机 JPEG 或其他 RAW 软件完全一致。LibRaw 预留为后续补齐能力，其打包、授权、体积与样片验收另立任务。
4. **分开视觉分布与线性测量。** 日常 RGB/亮度直方图明确共同分析空间、范围及归一化方式；专业亮度测量在高精度线性数据上进行。HDR 超范围像素不能一律标成过曝。SDR 映射预览只改变显示，分析不得跟着屏幕 headroom 波动。若首版仅提供 SDR 分析，应清楚标注并保留 HDR 原始数据，不能默默截断。
5. **报告事实与估计。** 拍摄参数显示为“文件记录值”，缺失则留空并说明。暖冷倾向、噪声或锐度只能按已定义算法显示为观察指标；不同内容的两张照片不自动给“摄影质量分”。白/黑场、高光/阴影用区域占比或百分位表达，注明阈值，不伪装为原作者编辑设置。

## 开发前仍需验证

- 建立授权可用的真实样片集：JPEG/PNG、16 位 TIFF、带 ICC 的 sRGB/Display P3/Adobe RGB、无配置文件图像、方向 metadata、透明像素、受支持与不受支持 RAW、同型号不同压缩模式、ProRAW/HDR。
- 在 macOS 14 与当前 macOS 分别验证，不用单台开发机的结果替代支持矩阵；RAW 预览与完整解码分别验收。
- 对缺失 ICC 的默认解释、RGB 直方图空间、亮度公式、HDR 白点、区域采样和精度预算定规范，并用可计算色块检验。
- 此笔记未运行实际 RAW 解码、色彩回归或性能测试；结论来自官方资料和 SDK 头文件核查，不能据此宣布功能完成。

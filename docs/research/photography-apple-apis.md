# 摄影对比：Apple 现成统计 API 核查

访问与本机 SDK 核查日期：2026-10-02。本文是实现前的 API 研究记录，不代表其中全部方案均已采用；当前实现见[摄影规格](../architecture/photography-comparison.md)。约束：专业指标、色彩变换和矩阵算法只采用 Apple 官方接口或另行验证的成熟专业开源库；项目负责输入管理、调用组合、交互和展示，不自行补写摄影算法。

## macOS 14 可采用的现成接口

下表的系统版本为本机 SDK 声明的接口可用版本；Core Image 列为类型化工厂方法的可用版本，不等同于同名传统滤镜最早出现年份。头文件核查位置为 SDK 中的 `CoreImage.framework/Headers/CIFilterBuiltins.h`、`MPSImage.framework/Headers/MPSImageHistogram.h` / `MPSImageStatistics.h`、`vImage.framework/Headers/Histogram.h` 和 `vecLib.framework/Headers/vDSP.h`。

| 能力 | 现成接口 | macOS 起始版本 | 结果和边界 |
| --- | --- | --- | --- |
| RGB/Alpha 直方图 | `CIFilter.areaHistogram()` / `CIAreaHistogram` | 11 | 对 `extent` 区域输出一像素高的数据图；`count` 为桶数，官方范围 1–2048；`scale = 1` 为归一化分布，不是原始像素计数。 |
| 按档位分布的 RGB 直方图 | `CIFilter.areaLogarithmicHistogram()` | 13 | RGB 在分桶前进行 log₂ 变换；支持 `minimumStop` / `maximumStop`。不能直接称为相机曝光参数或传感器动态范围测量。 |
| 区域平均颜色、逐通道极值 | `CIAreaAverage`、`CIAreaMinimum`、`CIAreaMaximum`、`CIAreaMinMax` | 11 | 是像素通道统计，不自动提供摄影语义的“整体亮度”“对比度”评分。 |
| GPU 通道直方图 | `MPSImageHistogram` | 10.13 | 对纹理区域输出计数；`clipRectSource` 支持选区；桶数须为 2 的幂，桶为 UInt32；调用者明确 `minPixelValue` / `maxPixelValue`。 |
| GPU 均值与方差 | `MPSImageStatisticsMean`、`MPSImageStatisticsMeanAndVariance` | 10.13 | 直接返回区域统计；方差不能未经定义就命名为专业摄影对比度。 |
| CPU 直方图 | `vImageHistogramCalculation_Planar8` / `ARGB8888`、`PlanarF` / `ARGBFFFF` | 10.3 | 8 位版本为 256 桶；32 位浮点版本可指定桶数及数值范围，不必降成 8 位。 |
| CPU 向量均值 | `vDSP_meanv` / `vDSP_meanvD` | 10.4 | 属于 Accelerate 的 **vDSP**；不要误称存在已核实的 `vImage mean` 接口。调用需正确处理步长与图像行填充。 |

官方来源：[Core Image 直方图](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/areahistogram())、[对数直方图](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/arealogarithmichistogram())、[MPSImageHistogram](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagehistogram)、[MPS 均值与方差](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagestatisticsmeanandvariance)、[vImage Histogram API](https://developer.apple.com/documentation/accelerate/histogram)、[vDSP_meanv](https://developer.apple.com/documentation/accelerate/vdsp_meanv)。

`CIAreaAlphaWeightedHistogram` 的类型化工厂方法从 macOS 15 可用，不能直接作为 macOS 14 基线。透明像素如何进入统计仍需定义；“不计算 Alpha 通道直方图”不等于“自动排除透明像素的 RGB”。

## HSL：本次没有核实到 Core Image 直接转换接口

官方滤镜文档及本机 `CIFilterBuiltins.h` 检索中，没有发现可直接把图像转换为 HSL 通道的现成 Core Image 接口。这个结论限定于本次核查，不能外推为整个 Apple 平台永远不存在该能力。

- `CIHueAdjust` 修改色相，不输出 HSL 分量。
- `CIHueSaturationValueGradient` 生成 HSV 色轮，不分析输入图片，也不是 RGB→HSL 转换。[Apple 官方说明](https://developer.apple.com/documentation/coreimage/cifilter/3228342-huesaturationvaluegradient)
- 确有 `CIFilter.convertRGBtoLab()`，macOS 13 起可用；它输出 CIELAB，不能改名为 HSL。可列为后续 Lab 明度/色度候选，需按真实输出定义展示。[Apple RGB→Lab](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/convertrgbtolab())

建议：HSL 必须选择并验证明确提供该转换的成熟专业库后再承诺；不以手写公式、自定义 shader 或填一组矩阵系数绕过用户约束，也不把 HSV/HSL/CIELAB 混称。

## 曲线：现成编辑滤镜不提供反推能力

`CIToneCurve` 接受五个控制点，插值成曲线并应用到图像 RGB。它属于正向调整接口，不读取图片的历史编辑曲线，也不从两张照片反推出作者如何调色。本机 SDK 注释与接口均明确输入为图像及控制点。[Apple toneCurve](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/tonecurve())

因此“曲线对比”需要先确定含义：若是图像的分布曲线，可以显示官方统计产生的直方图；若是原作者的编辑曲线，必须有相应编辑元数据及已验证解析器。不能把直方图、统计累计分布或自行拟合结果标成“原始调色曲线”。本轮也不引入曲线编辑功能。

## 数值与 RAW 的计量前提

1. **统计范围必须相同且明确。** `vImage` 浮点直方图会把小于下限或大于上限的数据并入首尾桶；MPS SDK 也说明同类行为。因此 HDR 用 0…1 统计时，尾桶混有超范围数据，不能直接显示成“过曝像素比例”。MPS 在线 `maxPixelValue` 说明中的“first entry”与本机头文件“last entry”不一致；实现前用色块样例核实端点行为，当前不掩盖文档差异。[vImage 浮点范围](https://developer.apple.com/documentation/accelerate/vimagehistogramcalculation_planarf(_:_:_:_:_:_:))、[MPS maxPixelValue](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagehistograminfo/maxpixelvalue)
2. **直方图不是色彩空间转换器。** 两边先经官方色彩管理转换到共同且公开的分析空间，保留高精度；线性 RGB 与编码 RGB 的分布含义不同。RAW 先经过明确记录的解码/显影，统计只能归属于该显影结果。不能拿嵌入预览作完整 RAW 统计。[相关 RAW 与色彩研究](photography-raw-and-color.md)
3. **读回的数据不能被当作普通照片再次调色。** Core Image 的直方图输出用像素通道承载数值；分析读回、精度和输出色彩转换需专门验证，不能把 UI 显示用的曲线图截图当统计结果。
4. **对数轴需要解释参考值。** 对数直方图的 stops 是相对于输入数值基准的 log₂ 分布；没有相机标定或场景测量时，不代表拍摄曝光偏差或真实场景动态范围。零、负值及超区间行为须做针对性样例验证，本轮未测试。
5. **官方基础统计不是“摄影鉴定”。** 优先承诺 RGB/对数直方图、区域均值和通道极值；HSL、亮度/色度定义、裁切阈值、噪声、锐度和镜头畸变指标逐项绑定成熟算法来源及适用条件。不能因调用了 Accelerate 运算函数，就把项目自行组合的指标称为官方专业指标。

建议首版主路径采用 Core Image 现成区域统计；CPU 计数需求选 vImage；只有明确性能需求再引入 MPS，避免同时维护三套等价后端。所有路径仍需真实样片、色块、透明像素和 HDR 边界验收，本文件不宣称已经验证输出数值。

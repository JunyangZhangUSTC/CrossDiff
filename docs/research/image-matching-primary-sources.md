# 图片智能对比：一手调研、工程边界与产品提案

调研日期：2026-10-04。状态：实现前研究，未运行匹配基准、模型推理或 Core ML 转换。算法资料研究先独立根据官方文档、论文和作者仓库展开，不读取用户附件；随后结合当前源码审计和附件核对，形成后半部分产品建议。本文件区分“来源已确认的能力”和“面向 CrossDiff 的设计建议”；建议不表示已实现或已验证。

## 推荐结论

**建议先实现可拒绝的 SIFT/RootSIFT + 几何验证基线，再用同一验收集决定是否引入学习型匹配。** 首版先解释裁剪、平移、旋转、缩放下的同源内容；遮挡、水印和局部修改通过剩余稳定特征建立参考关系。对局部移动和拼接输出多组区域对应候选；对不同拍摄视角输出“同一场景的对应内容”，避免承诺全部像素可比较。

学习型升级优先评估 **SIFT + LightGlue**，同时纳入 **XFeat** 作为轻量前端候选，**LoFTR-DS** 作为低纹理场景补充；**RoMa** 适合研究更稠密的对应置信度。它们都仍需几何验证、区域支持度和拒绝机制。当前 **EfficientLoFTR 作者仓许可证已是 PRL v1.0**，不应沿用旧的 Apache 印象直接纳入产品。许可细节见后文。

**不要以“把残差压到最低”为唯一目标自动扭曲图像。** 找到对应内容与判断修改是两个阶段；密集光流、自由网格或局部重排可能把用户正在寻找的位移、变形和拼接吸收进配准。应保留全局对齐下的差异，再另行展示局部对应与运动。这是针对比较产品的设计判断，不是某篇论文对 CrossDiff 的测试结论。

## 先定义“共有”的不同含义

| 输出 | 回答的问题 | 不应推导的结论 |
| --- | --- | --- |
| 语义相似 | 是否都画了同类物体、场景或概念？ | 两幅“猫的照片”不一定有任何同源像素或可配准内容，不能由语义相似自动叠加。 |
| 对应点／区域候选 | 两图中哪些纹理或结构可能来自同一内容？ | 有对应不等于像素相同，也不等于同一原始文件。 |
| 几何可比较区域 | 在明确的相似／仿射／单应变换下，哪里同时有有效采样？ | 图像边界的几何交集不等于整块内容均已验证；凸包内部可能有遮挡或替换。 |
| 内容差异 | 在已接受的几何关系下，哪些位置有颜色、纹理、结构或位置变化？ | 未匹配不直接等于删除；可能是遮挡、无纹理、重复纹理、视角或分辨率不足。 |
| 严格像素相同 | 在已声明的解码、颜色空间、位深和像素坐标下，样本是否逐值相同？ | 经缩放或旋转插值后的近似相等，不是源像素或源文件逐字节相同。 |

SIFT 最初就针对不同视图的局部对应，而非判断文件来源；其论文采用匹配、姿态一致性聚类及验证，处理遮挡与杂乱背景。因此“匹配到”只能成为关系证据，不能单独证明编辑历史。[Lowe，SIFT 原论文](https://www.cs.ubc.ca/~lowe/papers/ijcv04.pdf)

建议把结果分成“单一变换可解释”“存在多个局部对应”“可能为不同视角／非刚性变化”“证据不足”。这比输出一个貌似确定的相似百分比更符合上述证据边界。

## 候选方法的具体定位

| 方法 | 已确认的机制与适用点 | 对本任务的边界与建议 |
| --- | --- | --- |
| SIFT / RootSIFT + 最近邻 + RANSAC | SIFT 在尺度空间检测局部特征并按方向归一化；对缩放、旋转有设计上的不变性，对光照和三维视角变化只有一定鲁棒性。RootSIFT 是描述子变换，可作为同一基线的一个配置。[SIFT 官方说明](https://docs.opencv.org/4.12.0/da/df5/tutorial_py_sift_intro.html)、[OpenCV 匹配与 RootSIFT](https://docs.opencv.org/4.12.0/d5/d6f/tutorial_feature_flann_matcher.html) | 建议作为可解释、无需神经网络权重的首个质量基线。裁剪只要留下足够分布良好的纹理就有机会定位；低纹理、极小裁片、严重模糊、重复图案和重绘仍可能失败。不能把“SIFT 不变性”理解成任意尺度、任意遮挡均可匹配。 |
| ORB + Hamming + RANSAC | ORB 使用 FAST、方向估计和旋转 BRIEF；二值描述子通常按 Hamming 距离匹配，`WTA_K=3/4` 时用 `NORM_HAMMING2`。[ORB 官方说明](https://docs.opencv.org/4.12.0/d1/d89/tutorial_py_orb.html) | 适合纳入低成本对照。是否优先跑 ORB、何时升级 SIFT，应由目标 Mac 上端到端延迟和正确拒绝率决定；这里没有足够实测把 ORB 宣称为本项目质量默认项。 |
| LightGlue + 明确的特征前端 | 输入关键点与描述子，输出稀疏对应；自适应深度、关键点裁剪降低部分图像对的计算。它是匹配器，不能弥补前端完全没有检测到所需区域。[LightGlue 作者仓](https://github.com/cvg/LightGlue)、[ICCV 2023 论文](https://openaccess.thecvf.com/content/ICCV2023/papers/Lindenberger_LightGlue_Local_Feature_Matching_at_Light_Speed_ICCV_2023_paper.pdf) | 优先评估 SIFT + LightGlue，保留现有几何验证，便于隔离“前端不变、匹配器升级”的收益。也可比较 DISK／ALIKED；必须分别验证前端权重与匹配器权重、坐标和描述子约定，不能任意替换前端。 |
| LoFTR-DS | 不先依赖稀疏关键点检测；先粗尺度建立对应，再精细化，利用跨图上下文改善低纹理匹配。论文主要评价室内／室外相机姿态和定位，并非编辑差异分割。[CVPR 2021 论文](https://openaccess.thecvf.com/content/CVPR2021/html/Sun_LoFTR_Detector-Free_Local_Feature_Matching_With_Transformers_CVPR_2021_paper.html) | 适合稀疏特征不足时的候选补充。输出是半稠密／筛选后的对应，不是精确共有区域分割，更不证明无纹理处真实唯一。计算与内存需要按输入分辨率实测。原仓提供室内／室外及 DS／OT 权重，应记录具体选择。[作者仓](https://github.com/zju3dv/LoFTR) |
| EfficientLoFTR | 继续研究半稠密匹配的效率；作者提供 `full`／`opt` 和精度配置，当前示例基于 CUDA，仓库说明室外 MegaDepth 训练与室内域差异。[作者仓](https://github.com/zju3dv/EfficientLoFTR) | 可研究，不作为直接分发默认项：当前 PRL 项目登记条件、具体权重授权以及 Mac 运行均需先解决。[当前 LICENSE](https://github.com/zju3dv/EfficientLoFTR/blob/main/LICENSE) |
| XFeat | 面向有限算力的学习型特征，支持稀疏和半稠密匹配；作者报告了普通笔记本 CPU 实验。[作者仓与论文入口](https://github.com/verlab/accelerated_features) | 应列为轻量升级对照，不把作者的 CPU 结果外推为 Apple Silicon 实测。需验证缩放／大角度旋转、具体权重和端到端开销。 |
| RoMa | 返回稠密 warp 与 certainty，并能采样对应供几何估计；作者还提供较轻的 Tiny RoMa。[作者仓](https://github.com/Parskatt/RoMa) | 适合研究稠密支持度和复杂视角；可以从对应中估计受约束模型，不应默认用自由 warp 消除差异。主模型较重的风险、Mac 后端和完整权重许可仍需实测／核实。 |
| Apple Vision registration | `VNTranslationalImageRegistrationRequest` 做平移配准；返回类型虽然是 affine transform，不能由此推断它估计任意仿射。`VNHomographicImageRegistrationRequest` 返回透视单应矩阵。[平移 API](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest)、[单应 API](https://developer.apple.com/documentation/vision/vnhomographicimageregistrationrequest) | 适合原生低集成成本的对照候选。公开结果不是 SIFT 风格可审计的对应点集合；不宜只凭返回矩阵就宣告发现可靠重叠，更不能由 API 名称保证大裁剪、拼贴或多运动。 |
| 相位相关 / ECC | `phaseCorrelate` 估计平移；`findTransformECC` 优化指定模型下的相关性，存在收敛与初始化要求。[相位相关](https://docs.opencv.org/4.12.0/d7/df3/group__imgproc__motion.html)、[ECC API](https://docs.opencv.org/4.12.0/dc/d6b/group__video__track.html) | 同尺寸近似对齐或已有候选后的细化可作为实验；单独不足以覆盖任意裁剪／缩放／局部移动，不应以全图相关性替代区域发现。 |

## 几何模型决定哪些差异会被保留

| 模型 | 能解释的关系 | 本任务中的使用建议 |
| --- | --- | --- |
| 平移 | 图片位置变化、同尺度裁剪的坐标差 | 有充分证据时最简单、容易解释。 |
| 相似变换（平移＋旋转＋等比缩放） | 常见同源裁剪、旋转、缩放 | 首选全局模型；可用 `estimateAffinePartial2D`。反射不是此模型默认包含的变换，镜像需显式另建假设。 |
| 仿射 | 非等比缩放、剪切及局部平面近似 | 用 `estimateAffine2D`；只有较简单模型不足且独立验证改善时再接受，避免把实际拉伸编辑默认忽略。 |
| 单应（homography，8 自由度） | 平面透视、整张图片透视编辑；理想无畸变相机纯旋转 | 用 `findHomography`。平面场景或相机纯旋转有几何依据，存在深度与平移引起的视差时不能代表全图。[OpenCV 单应教程](https://docs.opencv.org/4.12.0/d9/dab/tutorial_homography.html) |
| 基础矩阵／本质矩阵 | 同一刚性三维场景的多视图极线约束 | 可辅助支持“不同视角”的解释；约束对应点落在极线上，不给出任意像素唯一的二维 warp。不能直接拿它生成可逐像素比较的整图。[OpenCV calib3d](https://docs.opencv.org/4.12.0/d9/d0c/group__calib3d.html) |
| 多个局部模型 | 独立移动／复制／重排片段，也可能是多个深度平面 | 输出区域对和各自变换；“多个模型”本身不能区分拼贴编辑与正常三维视差。 |

上述 OpenCV 估计器与稳健方法由 `calib3d` 提供；该版本文档也列出 USAC 与 MAGSAC 选项。采样最小点数只解决“能否求一个解”，不足以作为产品可信门槛；单应从少量或聚集在一小角的点外推到整张图尤其危险。[估计器与稳健模型 API](https://docs.opencv.org/4.12.0/d9/d0c/group__calib3d.html)、[特征匹配后估计单应的官方示例](https://docs.opencv.org/4.12.0/d1/de0/tutorial_py_feature_homography.html)

**设计推断：不能仅凭两图确定“同源编辑”还是“不同拍摄”。** 同一纸面从不同相机角度拍摄也能符合单应；编辑器透视变换也能符合单应。建议报告可观察证据：“单一二维变换解释了这些区域”“存在视差或多个变换”，将来源分类保留为候选解释。模型选择要依据残差、空间覆盖和复杂度，不能直接比较不同误差定义下的原始分数，更不能把基础矩阵内点更多当作确定的来源判别器。

## 可实施的首版基线

以下是建议的流水线，尚未选定默认阈值或跑过样本。

1. **固定输入和坐标。** 解码后先应用图像方向元数据，记录完整坐标映射；匹配用有界分辨率的副本，比较显示保留明确的色彩／透明度规则。全局灰度特征发现可以对色彩编辑保持鲁棒，但颜色差异仍在差异阶段报告，不能顺手做直方图匹配把调色消掉。
2. **提取特征。** SIFT 与 RootSIFT 作为两套固定配置评估；关键点在画面中做空间配额或覆盖检查，避免一处高纹理吃掉全部预算。极小裁剪可对候选区域做更高分辨率二次匹配；不能把 1600 像素预览没有找到的细节称为不存在。
3. **先过滤描述子歧义。** L2 最近邻匹配配合双向一致性和 ratio test；ORB 用相应 Hamming 范数。OpenCV 将 ratio、cross check 和几何检验列为互补筛选。阈值应在保留集上选择，不照抄示例数字作为通用真理。[OpenCV 匹配教程](https://docs.opencv.org/4.12.0/dc/dc3/tutorial_py_matcher.html)
4. **拟合多个复杂度的候选。** 稳健估计平移／相似变换，必要时再试仿射和单应；同一组对应的几何验证与模型打分统一记录。按独立留出点或空间分区交叉验证残差、空间支持、正反向一致性和变换合理性，选择足够解释证据的简单模型。
5. **设可靠性门。** 联合考察匹配数量、内点比例、空间覆盖、残差分布、重复纹理下的次优候选、变换退化和外推距离。覆盖率需分别相对 A、B 报告：一张小裁片覆盖原图仅一小部分可能完全正确，不能以“两侧都必须覆盖大面积”的规则拒绝。接近共线的点、病态矩阵、异常尺度或投影越过无穷远的模型均应拒绝或降级。
6. **保留几何交集与证据支持的区别。** 变换图像矩形／有效采样 mask 可以得几何重叠区；关键点邻域、分块复核和局部置信度给出已验证支持区。不要用内点凸包把其内部遮挡区域自动宣称为不变。透明像素的有效图像覆盖与 alpha 值独立处理。
7. **恢复源坐标。** 若分析缩放分别为 `S_A`、`S_B`，估计 A→B 的分析矩阵为 `H_a`，对应源图矩阵为 `S_B⁻¹ H_a S_A`；还要组合方向／裁剪／padding 的映射。始终携带原始坐标，避免把模型 resize 后的点直接画回原图。
8. **最后比较内容。** 在可靠几何范围内同时保留原始像素差异与结构差异的解释；插值、JPEG 重编码、锐化边缘、透明度和曝光会产生残差。低支持区域显示“未确认”；全局未匹配是正常可交付结果，允许手动选择区域后重试。

建议首版输出包括：对应点对、模型类型和方向、两侧覆盖范围、残差统计、分区支持度、变换参数、候选歧义和拒绝原因。将“匹配器置信度”“模型内点比例”和“已验证区域面积”分开，未经校准不合成“有 95% 概率同源”之类概率陈述。

## 局部移动、拼接与遮挡如何扩展

**区域发现建议：** 先接受主模型，再在未解释的对应中寻找变换一致、空间上聚集的候选，重复做局部稳健估计；同时允许用户选取 ROI 为候选提供约束。SIFT 原文的姿态聚类与验证提供了这种分组思路，但不等于已经提供完整的编辑检测器。[SIFT 原论文，第 6–7 节](https://www.cs.ubc.ca/~lowe/papers/ijcv04.pdf)

必须防止两类相反的错误：主模型把小的移动区域当作外点丢弃；无限迭代拟合又能从纯噪声凑出很多“小模型”。每个候选都应有独立的局部纹理证据、合理的支持面积和质量门，限制候选数并保留次优解释。重复窗格、文字行、相同 logo、复制出的多个对象可能存在一对多关系，不能由互为最近邻强行决定唯一来源。

**互为最近邻适合作为整体稳健配准的保守起点，但会排掉重复拷贝的一对多对应。** 后续局部候选发现不能照搬这个硬约束；应保留有限数量的描述子近邻／多候选，分别以各区域的几何与内容证据验证，再把仍然不唯一的对应明确展示为歧义。

建议并排呈现三类证据：主模型下的原始位置差异、带连线的局部区域对应、用户选择某区域后单独对齐的内容对照。局部区域的平移／旋转本身也是变更，应记录；将所有片段拼回“最相似”的位置后只显示低残差，会丢失编辑事实。

遮挡区或重新绘制区可以没有可靠对应。区域周围对齐成功有助于定位变化，却不证明遮挡下原本是什么。类似地，只用两张最终成片不能可靠判断一个物体是真的移动、被复制移动还是被重绘；产品应保留“疑似局部变化”的表达。

## 为什么不把密集光流作为默认最终对齐

光流估计逐像素位移；RAFT 通过全像素相关与迭代更新求流场，任务目标是运动对应，不是保留编辑事件。[RAFT 作者论文入口](https://www.ecva.net/papers/eccv_2020/papers_ECCV/html/3526_ECCV_2020_paper.php) Apple `VNGenerateOpticalFlowRequest` 也输出像素方向变化向量，要求两幅输入同尺寸，并提示计算消耗较高、一次只创建一个请求。[Apple 光流 API](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest)

**对差异产品的推断：** 若一个人物被液化拉宽，或文字块被移位，允许逐像素自由 warp 后，它们可能重新重合，使残差变小；这不等于修改消失。因此 dense matcher 和 optical flow 都可用于“发现哪部分可能对应”“指出局部运动”或辅助分块复核，默认差异图仍以用户接受的全局模型为参考。若提供“局部补偿”视图，必须显式开启，保留补偿前后切换和位移场，并将遮挡、低置信和正反向不一致的部分屏蔽为未知，而非涂成零差异。

光流不是 LoFTR 的同义词，LoFTR 也不是强制扭曲器。风险来自产品把任何预测对应直接转成过度自由的变形并以此定义“没有差异”，与模型名称无关。

## 代码、前端和权重许可要分开记录

以下为 2026-10-04 在线所见许可事实与待核实项，不把论文公开、仓库徽章或可下载视为整条依赖链均可分发。正式引入时应固定 commit、每个权重文件及 SHA-256、来源、许可证和第三方声明；本轮未下载模型，也未办理任何登记。

| 组件 | 已核验 | 采用前需解决的边界 |
| --- | --- | --- |
| OpenCV 4.12.0 的 SIFT／ORB | OpenCV 4.5.0 起采用 Apache-2.0；传统方法本身无预训练权重文件。[官方许可](https://opencv.org/license/) | 保留实际构建包含的第三方声明；不要从旧文档对专利时代的描述推导当前模块必须使用 contrib。 |
| LightGlue 匹配器 | 作者明确把自身代码和预训练 LightGlue 权重列为 Apache-2.0。[作者许可说明](https://github.com/cvg/LightGlue#license) | 前端不自动继承该许可。优先 SIFT 配套模型可减少额外学习型前端的依赖审计；仍需核对实际采用的实现和发布包。 |
| SuperPoint 前端 | LightGlue 明确提示 SuperPoint 推理文件及其权重另受限；Magic Leap LICENSE 限于非商业研究，授权不可转让、不可再许可。[LightGlue 说明](https://github.com/cvg/LightGlue#license)、[SuperPoint LICENSE 原文](https://github.com/magicleap/SuperPointPretrainedNetwork/blob/master/LICENSE) | 不因为 CrossDiff 免费或开源，就把该代码／权重直接随通用产品分发。可以选择许可清晰的其他前端，或另取得相应授权。 |
| DISK／ALIKED | DISK 作者仓为 Apache-2.0，提供仓内权重；ALIKED 作者仓为 BSD-3-Clause，提供 `models/`。[DISK](https://github.com/cvlab-epfl/disk)、[ALIKED](https://github.com/Shiaoming/ALIKED) | 按实际下载权重与子模块核验许可覆盖；ALIKED 原实现要求构建 `custom_ops`，不能据 PyTorch 代码就假定可原样在 Mac 上运行。作者也明确大角度旋转仍可能困难。 |
| 原版 LoFTR | 当前 master/LICENSE 为 Apache-2.0。README 提供独立下载的室内／室外权重，但对“所有这些外部 checkpoint 均以何许可分发”的明确程度不及 LightGlue。[LoFTR LICENSE](https://github.com/zju3dv/LoFTR/blob/master/LICENSE)、[作者仓权重入口](https://github.com/zju3dv/LoFTR) | 应核实选定 checkpoint 的授权覆盖。LoFTR-OT 要从 SuperGlue 获取受限代码，作者自己已警告许可严格；评估优先 DS，不把主仓许可当作 OT 整链许可。 |
| EfficientLoFTR | **当前 main/LICENSE 为 Project Registration License（PRL）v1.0，Copyright 2026。** 组织将其用于项目，包含非商业、研发、测试或部署，要求开始使用前登记；个人／纯学术评估另有条件。[作者 LICENSE](https://github.com/zju3dv/EfficientLoFTR/blob/main/LICENSE) | 作者链接的 Hugging Face 模型页面仍标 `apache-2.0`，与当前源码许可不同。[模型页](https://huggingface.co/zju-community/efficientloftr) 需按实际代码版本与权重分别澄清；不能静默用镜像标签消除差异，也不能声称历史版本已一并核验。 |
| XFeat | 作者仓显示 Apache-2.0 并提供权重和训练说明。[作者仓](https://github.com/verlab/accelerated_features) | 核实实际权重、可选 LighterGlue 与第三方组件的授权，不以仓库单个徽章代替完整发布审计。 |
| RoMa | 作者说明除 DINOv2 外代码为 MIT，DINOv2 为 Apache-2.0。[作者许可说明](https://github.com/Parskatt/RoMa#license) | 该句明确的是代码；正式打包前还要核对选定 RoMa、DINOv2、Tiny RoMa／XFeat 权重的来源及授权，不能扩大为“所有权重已确认 MIT”。 |

## 本地 Mac 部署的事实与尚未验证之处

当前 CrossDiff 平台下限为 macOS 14，已有 C++ `PhotoCVBridge`，但 OpenCV 仅构建 `core,imgproc` 并链接这两个模块。SIFT／ORB 与几何估计不是已经存在的完整依赖：需要扩展 `features2d`、`calib3d` 等及实际依赖并验证体积、编译和桥接；不能把“已经用了 OpenCV”写成零成本接入。[Package.swift](../../Package.swift)、[现有 OpenCV 构建脚本](../../scripts/prepare-opencv.sh)

本机 SDK 头文件确认平移／单应 Vision 请求从 macOS 10.13 提供，光流从 macOS 11 提供，低于项目平台下限；这只确认 API 可用，不代表真实输入上的识别质量、运行时间或坐标转换已通过验收。[Vision 平移](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest)、[Vision 单应](https://developer.apple.com/documentation/vision/vnhomographicimageregistrationrequest)、[Vision 光流](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest)

PyTorch 的 MPS 后端是 Mac GPU 运行路径，但“框架支持 MPS”不证明某个模型所有算子、精度、动态形状和第三方扩展都支持，更不说明性能优于 CPU。需在项目内独立环境测试 CPU／MPS；官方仓的 CUDA 示例与 NVIDIA 速度不能替代此测试。[PyTorch MPS 官方说明](https://docs.pytorch.org/docs/main/notes/mps.html)

Core ML 可作为交付候选，而非既成结果。LightGlue 的自适应层数／关键点剪枝是数据相关控制；简单 tracing 可能只保留示例输入经过的分支。Apple 文档明确说明 tracing 对此不总适用，scripted 模型支持仍有实验性说明。[Apple 模型转换](https://apple.github.io/coremltools/docs-guides/source/model-scripting.html) 可以评估固定层数、固定关键点预算、禁用部分自适应的导出版本，但必须重新验证对应点、有效性、速度和模型质量，不可把导出成功等同与原模型行为一致。

建议应用保持解码、颜色管理和 UI 原生；重任务在可取消后台执行，模型文件随安装包或用户明确选择的下载保存到规定位置，比较时离线。若先用 Python 完成研究，它只证明算法可运行，不证明可直接发布为 Swift/AppKit 应用。正式接入前需确定 Core ML、原生推理库或隔离 helper 中的一条受支持路径。

## 需要怎样的验收集才能作下一步选择

下表是待执行计划，**没有本轮跑分**。公开 pose／homography benchmark 可检验基本对应质量，但 CrossDiff 还需验证编辑能否被保留、无关图能否正确拒绝。

| 样本族 | 必须包含 | 主要观察 |
| --- | --- | --- |
| 可控同源 | 单独及组合的裁剪、连续角度旋转、缩放、非等比拉伸、镜像、JPEG、噪声、色调变化 | 已知坐标的变换误差；裁片覆盖率；错误接受；正确拒绝；旋转与缩放极端值要分桶。 |
| 局部编辑 | 水印、遮挡、删物、重绘、局部移位、复制多个实例、拼接重排 | 主关系是否仍可找；移动是否保留为差异；各区域对应的准确率和歧义；无对应区域是否被错误补齐。 |
| 多视图 | 平面重拍、相机纯旋转、带平移和深度的场景、运动物体、反光／曝光变化 | 单应能否正确限域；视差是否被错误当成编辑；是否拒绝不成立的逐像素比较。 |
| 困难负例 | 不相关图、相似但不同 logo、重复文字／窗格、纯色、低纹理、严重模糊、极小重叠 | 错误区域匹配、错误“高置信”比例；允许拒绝，不能为了召回强行接受。 |
| 产品运行 | 多种像素尺寸和长宽比、大图、小内存机器、CPU／MPS／拟采用的部署后端 | 从解码到结果的延迟、峰值内存、取消响应、UI 不阻塞、固定预算下稳定性；型号／系统／模型 hash 一并记录。 |

建议按图像来源分离调参与最终保留集，避免同一照片的不同合成裁剪同时进入两组；同时记录“接受结果的正确率”和“覆盖了多少真实可对应区域”。只有处理“无关图正确拒绝”和“局部编辑不被对齐抹掉”的结果达到产品要求后，才决定更重模型是否值得增加包体与部署复杂度。

## 差异度量不能替代对应搜索

SSIM 原作者将其定义为参考图与失真图之间的结构质量度量，并展示了 JPEG/JPEG2000 等失真的评价；它不是空间位置搜索器，也不识别修改原因。[SSIM 原论文说明](https://ece.uwaterloo.ca/~z70wang/publications/ssim.html) OpenCV contrib 提供 `QualitySSIM` 及局部 quality map 接口，可作为对齐后结构差异的候选；该模块不在项目当前的 core/imgproc 构建中，需单独选定版本和依赖。[官方 QualitySSIM API](https://docs.opencv.org/4.11.0/d9/db5/classcv_1_1quality_1_1QualitySSIM.html)

对 CrossDiff 的建议是保留严格像素查看，再评估有明确容差和颜色约定的结构差异。不要把局部 SSIM 直接阈值化为具有确定语义的“删除/遮挡/篡改”掩码，也不要用一个全图平均分掩盖小范围重要编辑。阈值、边界和重采样误差须通过实际样本验证。

## CrossDiff 现状与集成判断

以下来自当前仓库源码审计，不是算法实验：

- [基础图片解码与渲染](../../Sources/CrossDiff/ImageComparisonRenderer.swift) 使用 ImageIO 首帧、方向校正、有界缩略图，最大边 1600；变换后的联合画布还可能再次缩小。差异是 8-bit 预乘 sRGB 画布的逐通道比较，任何非零差值都计入。因此当前放大到 100%/400% 不等于回到原图精度，JPEG 和重采样也可能造成大量差异。
- [手动变换](../../Sources/CrossDiff/ImageTransformGeometry.swift) 支持平移、旋转、独立宽高缩放与翻转；四角操作不是任意透视变换。当前只有两侧各一个整体变换，不能表达多块内容独立移动或一对多复制。
- 当前 coverage 表示源矩形变换后的覆盖，与源 alpha 分开，不是可见物体或可靠对应区域。未来应分别保留几何覆盖、透明度、匹配证据、比较有效域和未分析区域。
- [依赖配置](../../Package.swift) 只链接 OpenCV 4.12.0 core/imgproc；[C 桥](../../Sources/PhotoCVBridge/include/PhotoCVBridge.h) 目前仅提供摄影直方图。自动特征和几何估计需要扩充 features2d/calib3d/flann；不能把现有 OpenCV 依赖等同于已有自动匹配。构建 stamp、SwiftPM 和直接 swiftc 链接配置需要同步维护。
- [图片状态模型](../../Sources/CrossDiff/ImageComparisonModel.swift) 已有后台计算、取消及过时结果检查，可继续使用。保留现有手动状态和只读原文件行为；自动结果应作为独立、可撤销的建议层。

## 建议的产品行为（尚未实现）

在现有图片工作台增加“智能对比”，保留并排、叠加、滑动与差异视图。不另起一个复杂工作台。

| 入口 | 行为 | 无可靠结果时 |
| --- | --- | --- |
| 整体自动对齐 | 识别同一图片经裁剪、旋转、缩放后的主要关系；预览变换及有效重叠后应用。 | 原位保留两图，说明原因，允许手动微调。 |
| 查找局部对应 | 给出成对区域卡片；点选一组时两侧同时聚焦，可在该组自己的坐标中比较。 | 显示未找到或存在多个候选，不编造唯一答案。 |
| 在另一侧查找 | 用户框选一块后，搜索另一图中的候选位置。可用于全图自动匹配失败、小裁剪和重复内容。 | 允许改变区域或人工选择候选。 |

默认只展示少量区域轮廓与简明结果；匹配点连线、几何误差和算法参数放入可展开详情。颜色不独自承担含义，标签和线型同步区分可靠对应、变化、歧义及未分析。区域轮廓仅表示比较范围，不能说轮廓内全部相同。

自动变换不应抹掉变化：用主要背景建立整体关系后，被移动的物体仍应显示为位置变化。若用户选择该物体的局部配对，可另外展示“局部对齐后的外观差异”，同时保留其原位置、移动量及变换记录。多区域不能各自变形后拼出一张看似无差异的全局图片。

匹配可以使用灰度、归一化等辅助表示，但差异验证必须另外保留原有颜色/亮度。给结构差异和颜色差异不同入口，亮度补偿默认关闭且显式标记。沿用严格像素查看；有容差的结果写成“在当前尺度和容差下未发现差异”，不称文件完全一致。

建议使用“对应区域存在外观变化”“此处未找到可靠对应”“超出共同视野”等描述。仅凭两张图，不能保证区分实际遮挡、删除后补绘、替换和重新拍摄，也不能恢复被遮住的原内容。

## 数据与工程边界（提案）

1. 独立 `ImageMatchingEngine` 返回候选和证据，`ImageComparisonRenderer` 负责展示。底层算法调用权威库，CrossDiff 实现任务调度、参数选择、证据合并和交互。
2. `ImageCoordinateSpace` 显式记录原图已定向尺寸、分析图尺寸及双向精确映射。不要把独立缩略图的坐标直接写入当前共享缩略图坐标的手动 transform。
3. `ImageRegistration` 保留映射方向、模型类型、矩阵、内点、残差、覆盖、有效域和拒绝原因。透视/剪切矩阵不能强行压成当前旋转与宽高缩放参数。
4. `[ImageRegionMatch]` 记录独立局部映射、双侧区域、多候选冲突关系和来源证据。整体配准的互为最近邻筛选有助于减少误配，但不能作为一对多重复内容搜索的唯一硬约束。
5. 低分辨率发现候选，局部更高分辨率验证；小区域应有独立的分块/框选搜索机会，不能依赖全图缩略图永远召回。原图解码、瓦片和 ROI 能力需要单独设计资源预算，不能假设 ImageIO 对所有格式都能高效局部解码。
6. 不把特征点数量、内点比例、凸包面积或 SSIM 分数直接标成“相同百分比”或概率置信度。分别报告匹配支持、局部残差和已分析范围；正式阈值由负样本与独立验证集决定。

## 推荐推进与验收

先完成可重复评测原型，再决定生产引擎；不因论文榜单或单张成功示例锁定方案。

- **第一步：整体对齐与拒绝机制。** 传统 OpenCV 基线与 Apple 配准在同一数据集对照；覆盖裁剪、缩放、旋转、翻转、遮挡、JPEG、轻微调色，以及无关图片。验收原坐标重投影误差、局部改动保留、错误接受和取消行为。只用最简单且证据足够的几何模型；未通过检验不应用自动变换。
- **第二步：选区查找和多局部对应。** 加入两块独立移动、复制多次、拼贴、重复纹理、极小裁剪和低纹理。不是简单重复 RANSAC 并删掉所有内点：共享来源、一对多与竞争模型需要显式处理。
- **第三步：学习型增强。** 在传统方案的固定失败集上评估 LightGlue、XFeat 等，再决定是否作为可选本地模型插件；RoMa/LoFTR 为困难视角与稠密对应的候选。分别验证导出支持、数值一致性、内存、包体和 Mac 延迟，不沿用其他硬件的宣传速度。

测试同时包含真实自有/授权图片和有已知变换、遮罩的合成变体。合成变体覆盖中文/英文截图的小字改动、照片、透明 PNG、重复图标、遮挡与同源局部移动；负样本包含同类但不同图片、相似布局、共同水印/边框、纯色和重复纹理。不同视角拍摄的三维场景单列评测，不能混成同源编辑任务。

几何配准误差、对应区域查准/召回、修改区域检出、错误接受率及资源开销分别统计；允许合法多解。精细区域边界另评测，不用稀疏点精度冒充逐像素分割质量。性能记录指定硬件、分辨率、参数、版本、冷/热启动和耗时分位数；本轮均未实测。

现有回归入口 [check-image-comparison.sh](../../scripts/tests/check-image-comparison.sh) 与 [check-image-workflow.sh](../../scripts/tests/check-image-workflow.sh) 可保留，新增匹配准确性语料和引擎检查；真实窗口仍串行验证中英文、浅深色、窄窗口及源文件不变。

## 与用户附件的对照

附件关于“先找局部对应，再验证差异”、SIFT/LightGlue/LoFTR 的定位和单一全局变换的局限，与独立查到的一手资料基本一致。它可以作为概念参考，不能替代 CrossDiff 的效果证明。

本提案进一步明确：失败和歧义是正常输出；整体对齐与局部移动需保留不同语义；重复拷贝需要一对多；预览分辨率不能承担精细差异承诺；颜色/形变不能被自动归一化悄悄消除；代码、前端模型与权重许可及 Mac 部署分别验证。本轮只形成调研与设计建议，未变更应用功能、未新增依赖、未运行准确率或性能基准。

## 2026-10-04：实现路径与可选模型资源

**后续实现状态（0.13.0 源码预览）：** 已实现本地 SIFT＋双向匹配＋RANSAC 整体相似变换和原生智能对齐入口，新增 `features2d`／`calib3d`／`flann`。上文源码审计描述的是实施前状态；当前行为与限制见[使用指南](../usage.md#compare-images)和[产品规格](../specification.md#0130-图片智能对齐)。局部多区域、透视及可选模型仍未实现。

用户已确认先采用 OpenCV 方案实现。OpenCV 基线无需神经网络权重，新增原生模块的安装包增量应在实际裁剪、链接与压缩后测量，不把“无模型”说成“安装包零增长”。

针对学习型方案，建议采用“内置基础算法＋可选模型资源包”：Base 和 Full 均保留完整 OpenCV 基础体验，学习型权重默认不预装；插件管理中显示可选增强能力，用户主动安装模型后启用，比较始终离线。Full 可以带扩展入口，模型资源单独计量，不将“全部功能入口”与“预装全部大权重”绑定。

模型资源与插件代码分开管理，避免重复模型、重复推理库和主应用升级时反复下载：

- 下载前展示具体版本、下载大小、预计磁盘占用和兼容要求；安装后显示模型及编译缓存实际占用。压缩下载、解压文件、系统编译缓存、峰值运行内存是不同数字。
- 官方资源通过对应 GitHub Release 附件提供，目录锁定版本、字节数及 SHA-256；只在用户操作时联网。支持项目计划中的本地模型包导入、取消下载和失败重试；断点续传需绑定相同版本／ETag 并在完成后重新校验。
- 使用流式临时文件及原子安装，不把大模型完整累计在内存；校验成功后登记。卸载提供模型与衍生缓存清理，仍被其他扩展共享的资源需核对引用关系。
- 优先验证系统 Core ML 推理，避免为了模型附带一整套 Python/PyTorch 开发环境；Core ML 转换、精度和动态输入兼容性尚未验证，不能提前承诺可用或精确安装体积。模型资源包仅承载受支持的模型数据，宿主负责推理和输入限制。

当前实现尚不支持这类模型包：[PluginPackage](../../Sources/CrossDiffCore/PluginPackage.swift) 是最多 16 MiB 的 JSON 插件格式，只含脚本或受信任可执行文件；[PluginDownload](../../Sources/CrossDiff/PluginDownload.swift) 同样限制 16 MiB，并将数据累计在内存；[OfficialPluginCatalog](../../Sources/CrossDiff/OfficialPluginCatalog.swift) 绑定现有插件扩展名、大小范围和受限 JavaScript 安装流程。因此需要增加独立的模型资源契约与下载存储层，不能只上调现有上限。本段记录设计方向，未实现资源下载器或模型推理。

### 上游原始权重体积核验

2026-10-04 通过官方仓库资产元数据及文件 HEAD 核验，未下载权重。以下统一使用十进制 MB（1 MB = 1,000,000 字节），不是最终发布包、Core ML 转换后体积或运行内存：

| 方案 | 权重文件及字节数 | 合计 |
| --- | --- | ---: |
| SIFT + LightGlue | `sift_lightglue.pth`：47,632,573 | 47.633 MB |
| XFeat | `xfeat.pt`：6,247,949 | 6.248 MB |
| XFeat + LighterGlue | 前者 + `xfeat-lighterglue.pt`：10,820,795 | 17.069 MB |
| RoMa outdoor + DINOv2 | `roma_outdoor.pth`：445,647,516；`dinov2_vitl14_pretrain.pth`：1,217,586,395 | 1,663.234 MB（约 1.66 GB） |

证据：

- LightGlue：[作者 Release API](https://api.github.com/repos/cvg/LightGlue/releases/tags/v0.1_arxiv) 的资产 `size`，对应 [SIFT 权重](https://github.com/cvg/LightGlue/releases/download/v0.1_arxiv/sift_lightglue.pth)。SIFT 不需要另一份学习型特征提取权重。
- XFeat：[作者 weights 目录 API](https://api.github.com/repos/verlab/accelerated_features/contents/weights) 的 `size`，对应 [XFeat](https://github.com/verlab/accelerated_features/blob/main/weights/xfeat.pt) 与 [LighterGlue](https://github.com/verlab/accelerated_features/blob/main/weights/xfeat-lighterglue.pt)。后者是可选的独立匹配器，不能把两者合计说成 XFeat 必需下载量。
- RoMa：[作者 Release API](https://api.github.com/repos/Parskatt/storage/releases/tags/roma) 中 outdoor 资产大小；[Meta 官方 DINOv2 文件](https://dl.fbaipublicfiles.com/dinov2/dinov2_vitl14/dinov2_vitl14_pretrain.pth) HEAD 返回 HTTP 200、`Content-Length: 1217586395`。[模型加载入口](https://github.com/Parskatt/RoMa/blob/main/romatch/models/model_zoo/__init__.py) 分别加载两者；[编码器](https://github.com/Parskatt/RoMa/blob/main/romatch/models/encoders.py) 将 DINOv2 放在普通列表中，没有注册进匹配器 `state_dict`，因此合计不重复计数。[构造代码](https://github.com/Parskatt/RoMa/blob/main/romatch/models/model_zoo/roma_models.py) 使用 `cnn_kwargs=dict(pretrained=False, ...)`，不额外叠加独立 VGG 下载。室内／室外模型可共享 DINOv2。

[Apple Core ML 转换文档](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html) 支持 ML Program 的 float16／float32 精度及独立权重文件，但不能据此把上表直接折半作为发布体积。应先验证转换、算子与输入尺寸、数值误差及目标 Mac 的速度和内存，再决定提供哪个增强包。当前优先评估 SIFT + LightGlue 对现有 SIFT 基线的增益；XFeat 作为轻量候选，RoMa 不进入默认安装。

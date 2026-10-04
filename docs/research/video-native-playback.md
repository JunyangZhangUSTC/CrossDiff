# 视频插件：Apple 原生播放与取帧调研

调研日期：2026-10-04。状态：设计依据，尚未实现视频插件，也未验证双路视频的实际性能。目标平台沿用 [Package.swift](../../Package.swift) 的 macOS 14+。本文件区分官方 API 能力、产品建议与仍需实验的结论，不把编译通过当成播放验收。

## 推荐路线

首版采用 **AVFoundation 原生解码与播放，统一控制两侧；暂停时提供可靠的成对帧检查**。先交付并排浏览、联动播放、时间偏移、选段循环、逐帧、暂停后的滑动对照和差异查看。专业取帧、色彩处理独立于 SwiftUI 页面；不要让两份 `VideoPlayer` 各自播放后就宣称实现了视频 diff。

实时浏览与精确检视有不同要求。前者需要流畅，后者需要知道到底比较了哪两帧。首版可以明确“播放中预览，暂停后精确检查”；用户不需要面对解码参数，但界面应保留左右真实时间和没有对应帧的状态。以下路线是工程建议，不是 Apple 对双路无误差同步的保证。

## 时间与输入信息

使用 `AVURLAsset` 异步读取时长、视频轨、音频轨、画面尺寸、方向变换、编码描述、名义帧率和色彩元数据。`AVAsset` 的 `isPlayable`、`isReadable` 与轨道 `isDecodable` 是不同能力：能播放不自动等于能提取像素。避免在主线程使用可能阻塞的同步属性。[异步属性](https://developer.apple.com/documentation/avfoundation/avasset-async-properties)、[轨道属性](https://developer.apple.com/documentation/avfoundation/avassettrack-async-properties)、[异步访问说明](https://developer.apple.com/documentation/avfoundation/avasset-deprecated-symbols)

时间模型使用 `CMTime`，保存比较时间到左右源时间的映射。首版可限制为固定偏移，不需要提前实现任意剪辑映射。`AVURLAssetPreferPreciseDurationAndTimingKey=true` 表达愿意承担更长的加载时间来换取精确时长和随机访问；这不是立即完成或零成本的承诺。[精确时间选项](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)

**不要用 `帧号 / nominalFrameRate` 代替真实时间戳，也不要用 `duration × fps` 冒充准确总帧数。** 名义帧率是轨道级信息；Apple 还专门指出按场存储的视频可能返回场率。不同样本可能有不同的显示／解码顺序，样本本身提供显示时间戳。VFR、29.97 与 30 fps、重复帧和编辑列表均应以实际呈现时间处理。[名义帧率](https://developer.apple.com/documentation/avfoundation/avassettrack/nominalframerate)、[样本时间戳](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetpresentationtimestamp(_:))

建议联动逐帧时明确一个基准侧：前进到基准侧下一真实样本时间，再用映射选择另一侧在该时刻覆盖的帧；另一侧可能仍显示上一张帧，这是帧率不同的正常结果。不能左右各调用一次 `step(byCount: 1)` 就声称时间同步。需要反向检查时切换基准侧，避免遗漏较高帧率一侧独有的帧。Apple 的步进大小取决于启用的轨道，还需检查 `canStepForward`／`canStepBackward`。[逐步播放 API](https://developer.apple.com/documentation/avfoundation/avplayeritem/step(bycount:))

`AVSampleCursor` 可辅助查询显示顺序和帧时间，但需先检查轨道能否提供游标；当资源没有精确时间信息时，游标定位也可能近似。首版不假设所有原生可播放文件均有随机样本索引。[游标定位](https://developer.apple.com/documentation/avfoundation/avassettrack/makesamplecursor(presentationtimestamp:))

## 三类取帧接口的分工

| 接口 | 适合用途 | 产品中必须承认的边界 |
| --- | --- | --- |
| `AVPlayer` + `AVPlayerLayer` | 流畅播放、音视频同步、原生 HDR 预览 | 控制时间基不等于两块图层在每次刷新都显示同一比较时刻的帧。 |
| `AVPlayerItemVideoOutput` | 获取正在播放的解码帧，交给 Core Image／Metal 统一绘制 | 取帧可能暂时没有新数据；返回的显示时间必须记录。不是任意时间点都可即时调用的离线解码器。 |
| `AVAssetImageGenerator` | 时间线缩略图、暂停检查的按需图片 | 请求时间与实际时间可能不同；精确容差会增加解码等待。不能把缩略图默认容差用于精确差异。 |
| `AVAssetReader` + `AVAssetReaderTrackOutput` | 后台顺序遍历、构建时间索引／分析缓存、受控样本读取 | 需要管理读取状态、取消、范围和有界缓存；不要为每次拖动从头解码整段视频。 |

以上对应 Apple 的 [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)、[VideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)、[ImageGenerator 结果](https://developer.apple.com/documentation/avfoundation/avassetimagegeneratorcompletionhandler)、[AssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader) 契约。

精确暂停图应将 ImageGenerator 前后容差设为零，保存返回的 `actualTime`，等待两侧同一版本请求完成再原子发布。拖动过程先出低分辨率近似预览，松手后补精确帧；快速拖动时取消旧请求并拒绝过时回调。这是产品调度设计。Apple 明确说明零容差请求帧精确生成可能增加解码延迟。[取帧容差](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/requestedtimetolerancebefore)

`AVPlayer.seek` 也有零容差的精确形式，但完成回调、玩家时间与真实显示帧是不同信号。播放器 seek 可以负责定位；像素差异仍要以取到的帧及其时间为准。[精确 seek 与额外解码延迟](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/ExploringAVFoundation/ExploringAVFoundation.html)

## 双路同步的真实保证

### 两个 AVPlayer，共享传输控制

Apple 提供 `preroll(atRate:)` 预备播放管线，再用 `setRate(_:time:atHostTime:)` 将源时间锚定到同一个未来 host time。调用后者之前必须设置 `automaticallyWaitsToMinimizeStalling=false`，否则可能抛出异常。该接口明确**不保证媒体在时间基开始移动前就已加载好**。[同步时间基](https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:))

因此首版协调器需要等待两侧 ready、完成 seek 和 preroll，再一起启动；任一侧中断、失败或结束时，由协调器决定暂停两侧或进入无对应内容状态。`preroll` 必须在播放器 ready 且速率为零时使用，并处理被 seek／速率修改中断的结果。[预加载前置条件](https://developer.apple.com/documentation/avfoundation/avplayer/preroll(atrate:completionhandler:))

`sourceClock` 可以指定时间基来源，但选错音频设备时钟反而会造成音频漂移。首版音频只选择左、右或静音，不同时播放两路，也不为了“统一”时钟就盲目覆盖 AVPlayer 的默认音频时钟。[sourceClock](https://developer.apple.com/documentation/avfoundation/avplayer/sourceclock)

`AVPlayerPlaybackCoordinator` 面向连接群组的协调播放／SharePlay；它不是本机两段不同视频精确配对的现成引擎。CrossDiff 不应引入远程会话来解决本地对照。[PlaybackCoordinator](https://developer.apple.com/documentation/avfoundation/avplayerplaybackcoordinator)

### 同一个显示回调，合成两路帧

更严格的显示方案是一个显示回调和一个 Metal 画布：从左右 `AVPlayerItemVideoOutput` 提取对应源时间的帧，再一次合成并排、滑动或叠加视图。Apple 的视频输出提供 host time 到 item time 的转换，以及返回像素和实际显示时间的接口。[VideoOutput 取帧](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/copypixelbuffer(foritemtime:itemtimefordisplay:))、[ItemOutput 时间转换](https://developer.apple.com/documentation/avfoundation/avplayeritemoutput)

**同画布能让已选择的一对帧一起呈现，但不能让尚未解码的帧凭空及时出现。** 一侧暂时没新帧可能是正常的低帧率覆盖，也可能是解码落后，必须结合真实时间判断。不能静默拿另一时刻的旧帧生成热图。需要保持上一完整帧对、显示等待，或暂停重新定位；具体策略应先做压力原型。

完全由统一时钟驱动两个 Reader／自管样本渲染器，控制最充分，但要自行处理缓冲、前后 seek、帧重排、音频、输出时钟和 HDR。这超出首版的必要范围，不能只因有 `AVAssetReader` 就视为简单播放器替代品。该复杂度判断是工程推断。

| 首版选择 | 浏览体验 | 严格检视 | 建议 |
| --- | --- | --- | --- |
| 双 AVPlayerLayer + 统一控制 | 原生路径，较容易保持流畅 | 暂停后切到已核实时间的静态帧对 | 首版基线；实时阶段不显示冒充精确的数值差异。 |
| 双 AVPlayer + 单 Metal 画布 | 支持同画布滑动和叠加 | 可显式管理帧对与显示时间 | 做短原型验证后采用；预算允许可作为同一首版的升级。 |
| 全自管 Reader／解码时钟 | 成本高、边界多 | 控制力度最大 | 等真实需求与前两种方案的瓶颈出现后再投入。 |

## 色彩、HDR 与差异的口径

原生 `AVPlayerLayer` 对支持的 HDR 内容可自动使用 EDR；实际效果仍取决于内容、设备和显示器。EDR 余量也会随显示状态变化。**能正常显示 HDR，不等于把截出来的 8 位 RGB 相减就能得到可靠的 HDR 差异。** 这是显示能力与测量口径的区别。[Apple EDR 说明](https://developer.apple.com/videos/play/wwdc2021/10161/)

Apple 给出了可用于自定义管线的官方方法：VideoOutput 请求宽色域、线性传递函数与 half-float 像素；输出到设置扩展线性色域、`RGBA16Float` 和 EDR 的 Metal 图层。可由系统完成相关像素色彩转换。CrossDiff 应采用该原生路径评估，而非自己实现颜色矩阵或假设所有视频均为 sRGB。[AVFoundation 与 Metal 的 HDR 管线](https://developer.apple.com/videos/play/wwdc2022/110565/)

建议把颜色能力拆成两项：

- **原始外观预览**：原生播放；读取并展示可获得的 HDR、色域与传递函数信息。
- **规范化像素对比**：明确两侧使用相同工作色域、传递函数、方向、像素纵横比、采样尺寸和有效区域；计算发生在显示器最终映射之前。不同分辨率的重采样与时间映射本身会影响差异，应让用户知道当前比较口径。

首版优先验证 SDR 的暂停帧对。HDR 可以保留原生对照预览，但若线性浮点帧、元数据或显示映射没有验证，就暂不提供声称精确的 HDR 数值／热图。系统不同路径的色调映射不得误报成原视频修改。缺失色彩标记的素材也应标“色彩信息不完整”，不要伪造绝对判断。

本机 SDK 核对发现 `AVAssetImageGenerator.dynamicRangePolicy` 从 macOS 15 才提供，因此不能把新系统上的 `.matchSource` 方案直接用于 macOS 14。14 上 HDR 精确暂停图的来源须用 VideoOutput／Reader 管线另行验证；普通缩略图不作为 HDR 测量依据。[ImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator)

## 格式、硬件与本地处理

首批验收以 MOV／MP4 容器中的 H.264、HEVC，以及 MOV ProRes 样例为目标，不以扩展名宣称全部文件可解码。实际应探测资产、轨道与首帧，并报告“能读取信息但无法解码画面”等具体结果。MKV、WebM、AVI 等只在系统和实际样例验证后标可用；首版不默认下载额外解码器。Apple 将播放、读取、轨道解码分别暴露为能力查询，支持这种逐层探测。[资产能力](https://developer.apple.com/documentation/avfoundation/avpartialasyncproperty/isplayable-45h5v)、[轨道能力](https://developer.apple.com/documentation/avfoundation/avassettrack)

`VTIsHardwareDecodeSupported(codecType)` 只回答当前系统是否支持该编码的硬件解码；不能据此保证某一 profile、分辨率、位深和两路并发都能实时，也不能声称 AVPlayer 此刻一定使用硬件。双 4K／高帧率、长 GOP 和 HDR 的内存与延迟必须实测。[VideoToolbox 查询](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:))

限制只接收用户选择的本地 URL；初版拒绝受保护内容、直播／网络地址、外部引用素材。为 `AVURLAsset` 显式设置 `AVURLAssetReferenceRestrictionsKey` 为 `.forbidAll`，使容器不能引用另外的本地／远程媒体；不把“入口是一个本地文件”当作天然不会跟随外部引用的证明。此限制可能拒绝 QuickTime reference movie，应明确提示。[引用限制](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions)、[forbidAll](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions/forbidall)

## macOS 14 可用性与原型门槛

本轮查阅 Apple 官方网页，并核对本机 Apple SDK 头文件的可用性：`sourceClock` 从 macOS 12 可用，ImageGenerator 的单图异步生成从 13 可用，`CADisplayLink` 在 macOS 从 14 可用，VideoOutput 的 `init(outputSettings:)` 从 10.12 可用。阅读最新版在线文档时需注意：新文档中的部分 replacement API 和 HDR 选项高于项目系统下限，不能因为旧入口标 deprecated 就无条件改成最新入口。

项目内 `.build/video-design-api-probe.swift` 已通过 `swiftc -swift-version 5 -target arm64-apple-macosx14.0 -typecheck`，用于 API 类型／可用性检查，不是应用实现，也不会提交构建缓存。它不验证真实播放、解码速度、颜色准确性或 GPU 行为。

以下内容必须先有真实原生原型，之后才能形成承诺：

1. **时间准确性**：用嵌入可见编号和真实 PTS 的合成视频，验证 24/30/60 fps、29.97 fps、VFR、非零起点、不同长度、长 GOP、正反步进与快速连续 seek；停止时两侧版本一致、时间标签对应像素。
2. **同步与降级**：对照源时间误差、掉帧和首次就绪延迟；一侧慢解码时不生成虚假差异，不继续播放已失配的声画。双 4K/60 是否可用必须按设备和编码记录。
3. **色彩一致性**：同一素材在 native preview 与检视帧间切换不能明显跳色；覆盖 SDR、HLG、PQ、广色域、旋转元数据、像素纵横比和缺失色彩标记。
4. **资源与取消**：有界缩略图缓存，播放时降低后台分析优先级；换输入／关标签及时取消，旧帧不写回新会话，原文件不变。
5. **离线与失败体验**：无音轨、多音轨、损坏文件、不能解码、受保护素材和外部引用素材均可解释；不自动联网补组件。
6. **界面验收**：浅深色、中英文和最小窗口尺寸下检查真实父窗口；采用统一的 `ComparisonTheme`、文件头和底部播放条，播放画布周围保持中性色，避免装饰性渐变影响对画面的判断。

本轮只产出设计调研，没有测得实际双路同步误差、编解码格式矩阵、HDR 精度或性能上限。

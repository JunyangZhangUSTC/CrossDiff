# Video Compare / 视频对比

官方视频插件 `org.crossdiff.video`，版本 `0.1.0`，需要 CrossDiff **0.14.0 或更新版本**。旧版宿主不认识 `videoAnalysis` / `videoTimeline`，会拒绝安装，不会回退为文本或十六进制解析。

本地只读视频工作台沿用 CrossDiff 的双栏、主题和中英文界面。原生宿主管理播放、手动时间对齐和暂停帧对照；此受限 JavaScript 插件只接收选定视频轨道的技术信息，并逐字段整理差异。**技术信息一致不代表画面相同。** 首版没有自动片段匹配、视频质量打分或视频导出。

## 安装与支持范围

- Full 预装；Base 包含相同的原生视频能力，可通过插件页或拖入 `.crossdiffplugin` 安装入口插件，无需另装音频或摄影插件。
- 首版声明 `.mov`、`.mp4`、`.m4v` 容器。实际编解码支持由当前 macOS AVFoundation 决定；扩展名不能保证成功解码。单个视频时长上限为 24 小时。
- 应用不重新编码或修改视频；该插件不会联网、读取文件路径或启动播放。受限 JavaScript 不是操作系统安全沙箱。

## 协议边界

输入为 `videoAnalysis`，结果视图为 `videoTimeline`，结果协议为 `crossdiff.video/1`；仅允许左右两方比较。整体宿主协议版本仍为 1。

每侧输入只包含 `id`、`name`、`duration`、`width`、`height`、`nominalFrameRate`、`codec`、`hasAudio`、`isHDR`。时长是 `{ "value": "600", "timescale": 600 }` 形式的精确有理时间；`value` 通过十进制字符串传递，避免整数精度丢失。尺寸是应用轨道方向变换后的显示尺寸；名义帧率为 `0` 表示无法取得，不能据此认定恒定帧率；HDR 只反映已知传递函数标记，不代表屏幕经过校准。

首版请求 `options` 必须为空。插件结果 `payload` 只允许 `metadataDifferences` 字段名数组与固定的 `contentCompared: false`。宿主重新核对差异字段，拒绝伪造的元数据差异、额外路径、对应关系和质量评分。播放器、缩略图、空间区域及时间偏移由宿主管理，不把它们的能力暴露给 JavaScript。

## 开发

在项目根目录运行：

```sh
source scripts/project-env.sh
bash scripts/tests/check-video-plugin.sh
python3 scripts/package-video-plugin.py
```

产物为项目内 `dist/Plugins/Video.crossdiffplugin`。统一发布清单还会生成 `CrossDiff-Plugin-Video-0.1.0.crossdiffplugin`，与完整版一起分发。

---

The official Video Compare plugin requires **CrossDiff 0.14.0 or later**. Full includes it; Base can install the same independent package. The host uses Apple frameworks for local, read-only video playback and paused frame comparison. The restricted script receives bounded source metadata only: no paths, video frames, audio samples, networking or playback access.

Initial containers are MOV, MP4 and M4V, subject to AVFoundation codec support and a 24-hour duration limit. Manual timing is a viewing assumption, not proof that the complete recordings correspond. Automatic segment matching, quality scoring and video export are not part of this release. `crossdiff.video/1` reports exact metadata differences and `contentCompared: false`; matching metadata must never be interpreted as identical picture content. Restricted JavaScript is not an operating-system sandbox.

# 音频自动匹配 M0 实证与生产边界

日期：2026-10-02。本记录覆盖指纹引擎与本机 helper，不代替完整窗口、音频解码、播放和插件安装验收。

## 已实现和执行的部分

生产候选为固定官方 [Olaf C 源码](https://github.com/JorenSix/Olaf/tree/a98d8c03cfd447011d402718ca2d10b2bb467eb0)。`CrossDiffAudioMatcher` 是独立原生进程，读取 Apple 解码器导出的 16 kHz 单声道 Float32 PCM。它索引左侧，按 12 秒窗口／6 秒步长查询右侧，保留不同偏移下的多段、重复和乱序对应；只合并时间重叠且偏移相近的证据，不把整文件强制拉成一条映射。

算法源码与各依赖许可证在 [ThirdParty/AudioMatching](../../ThirdParty/AudioMatching/README.md) 记录。唯一 vendor 改动把 LMDB 的虚拟映射上限从 1 TiB 改为 512 MiB，不改指纹算法。生产包不需要 Python、JVM 或 FFmpeg；这些只用于本轮研究对照。

限制包括每侧最长两小时、每查询窗最多 64 条返回、最终最多 512 候选、90 秒 CPU 和 120 秒墙钟预算。macOS 对有限 `RLIMIT_AS` 的设置失败，不能假装限额生效；改用独立线程每 100 ms 读取 Mach 常驻内存，超过 768 MiB 结束 helper。这是采样监控，不能保证分配瞬时完全不越界。短于两秒的输入返回 `partial`；数量上限触发也返回 `partial`。错误、内存／索引容量耗尽或超时都返回失败，不当作“没有差异”。窗口搜索完成不代表所有真实对应都已找到。

Swift 包装位于 `AudioMatchingEngine.swift`，只在私有任务目录生成 PCM 派生索引和短 JSON，终止／失败后清理。取消先终止 helper，必要时强制结束该子进程；不会终止主应用或用户进程。来源文件不写入。

## 原生回归

运行 `bash scripts/audio-research/build-matcher.sh` 后执行 `python3 scripts/audio-research/check-matcher.py`，结果通过：

| 可观察行为 | 结果 |
| --- | --- |
| 同一音频 | 找到对应 |
| 截取 10–27 秒 | 找到正确源区间及偏移 |
| 27–39 秒＋4–16 秒重排 | 两段均找到，无全局单调假设 |
| 9–21 秒重复两次 | 两个右侧位置均找到 |
| 不同前奏后附加参考尾段 | 找到尾段，没有只测整窗而遗漏结尾 |
| 增益降低 | 找到对应 |
| 独立随机音频、静音 | 未报告候选 |
| 原始 PCM 哈希 | 运行前后保持一致 |
| 1 秒输入 | 明确返回部分分析且无候选 |
| 80 个 1.5 秒短重复片段 | 64 条短候选上限触发，虽均不足两秒而不显示，仍明确返回部分分析 |
| 非法 PCM 长度、FIFO | 拒绝；FIFO 不等待写入者 |

素材由固定种子生成谐波与打击声混合，不含用户音频。LMDB 需要 macOS 进程同步接口，受限工具沙箱首次运行返回 `Operation not permitted`；在获得工具自动审查授权的原生运行环境下以上检查通过。不能把首次环境错误当作算法通过。

短重复片段回归先在旧 helper 上复现 `partial: false`，修复后返回 `true`。原因是上游先取最高分的 64 条候选再过滤短于两秒的候选，宿主只数过滤后的回调会漏掉截断。现在在宿主回调内应用相同的两秒展示门槛，上游时间过滤设为零，以观察完整 shortlist；不修改上游源码、指纹算法或最终显示门槛。达到 64 条时保守报告部分分析。

## 真实录音的小样本验证

来源来自 librosa 官方示例资料，下载只存项目 `.build/audio-research/real`，没有加入发行包：

- **音乐：** Kevin MacLeod — *Vibe Ace*，CC BY 3.0。[原始出处与许可](https://librosa.org/data/audio/Kevin_MacLeod_-_Vibe_Ace.txt)
- **语音：** Garth Comira 朗读 *Ashiel Mystery*，LibriSpeech SLR12，CC BY 4.0。[出处与许可](https://librosa.org/data/audio/5703-47212-0000.txt)

`prepare-benchmarks.sh` 固定音频与 audfprint 源码 SHA-256，固定项目内 Python 依赖版本；`benchmark-real.py` 保存变换后的样本和各引擎输出。10 秒片段从源录音第 2 秒开始。变换使用当前本机已有 FFmpeg 8.1.2 的 `atempo`、`asetrate`、`aresample`，不是生产依赖。

| 10 秒查询 | Olaf 音乐 | audfprint 音乐 | Olaf 语音 | audfprint 语音 |
| --- | --- | --- | --- | --- |
| 原片截取 | 命中 | 命中 | 命中 | 命中 |
| 独立 tempo ×1.1 | 无候选 | 无命中 | 无候选 | 无命中 |
| 独立 pitch ×1.1 | 无候选 | 无命中 | 无候选 | 无命中 |
| 播放速度 ×1.1，音高联动 | 无候选 | 无命中 | 无候选 | 无命中 |
| tempo ×1.15、pitch ×0.95 | 无候选 | 无命中 | 无候选 | 无命中 |

正式候选阈值为 20 个地标匹配、支持时长至少两秒。早期 15 地标阈值在音乐 tempo ×1.1 上出现一条低分固定偏移候选，与真实随时间变化的映射不一致；因此提高了首版阈值，并明确候选还需试听核对。它说明“有返回”也不能自动等同“准确识别变速”。此小样本不能用来估计一般误报率。

两种真实原片均返回了正确偏移约两秒；边界属于实际指纹支持范围，会收缩，不是精确剪辑边界。原生 helper 在这组短样本上约 0.01–0.03 秒完成，但没有测长音频或跨硬件性能，不能宣传成固定处理速度。

## Panako 增强路径已真实跑通，但未并入生产

本轮实际运行了 Java 17 arm64、Panako 官方 2.1 fat JAR，然后编译当前固定源码 `f1248f7a35a06af449f02f7df33c4cfdc1aeedc1` 做核对。官方 fat JAR 自带 JGaborator dylib 为 x86_64，首次在 arm64 上失败。显式把官方 JGaborator 0.7 放到研究 classpath 前端后，成功加载 arm64 原生库。

`PanakoPair.java` 显式创建 `PanakoStrategy`，采用内存索引并关闭文件缓存，没有使用会切到 Olaf 的 `panako same` 命令。JDK、JAR、源码、编译输出、Java user home 与 JNI 临时文件都位于项目中。固定下载地址和摘要见 `scripts/audio-research/prepare-panako.sh`；运行入口为 `benchmark-panako.py`。

| 查询 | 原片 | 独立 tempo ×1.1 | 独立 pitch ×1.1 | 联动 speed ×1.1 | tempo ×1.15、pitch ×0.95 |
| --- | --- | --- | --- | --- | --- |
| 音乐 10 秒，第 2 秒起 | 命中 | 无命中 | 无命中 | 无命中 | 无命中 |
| 语音 10 秒，第 2 秒起 | 命中 | 命中 | 无命中 | 无命中 | 无命中 |
| 音乐 20 秒，第 20 秒起 | 命中 | 命中 | 命中 | 无命中 | 无命中 |

20 秒音乐 tempo ×1.1 返回的参考支持区间约 21.92–37.61 秒、查询约 1.82–16.08 秒，符合已知时间映射；pitch ×1.1 返回近似同长区间与约 1.10 的原始 frequency factor。这里确认了独立变换能力可以实际工作，也暴露了片段内容、长度和组合变换的明显影响。没有修改默认阈值去迎合这些样本，也没有把未命中解释成音频一定不同。

Panako 仍需更广的语音／音乐／噪声数据、多窗口编排、因子方向校准、边界细化和完整打包评估。此次主程序交付的是固定速度候选匹配；自动独立变速／变调仍是研究后端，不能在 README 或 UI 宣称已全面支持。

## 复现与剩余验收

```sh
bash scripts/audio-research/prepare-benchmarks.sh
source scripts/project-env.sh
python3 scripts/audio-research/check-matcher.py
python3 scripts/audio-research/benchmark-real.py
bash scripts/audio-research/prepare-panako.sh
python3 scripts/audio-research/benchmark-panako.py
```

依赖下载需要网络；执行比较本身不联网。下载脚本仅为研究，不随最终应用运行。配置、缓存和源码均为项目级，不修改 `HOME`，不做全局安装。

尚未由此记录验证：两小时压力与峰值内存、更多真实短语音／中文语音、重叠混音和复杂连续变速、经过降噪／混响的录音、大量相同副歌的歧义。对应候选必须保持可审阅，允许用户手工选择局部，不把候选分数显示为正确概率。

# Audio Compare 0.11.0 验收记录

日期：2026-10-02。环境：Apple silicon、macOS 26.6.2、Swift 6.3.3；工程采用 Swift 5 语言模式，部署下限仍为 macOS 14。此记录是本地源码预览验证，不代表 GitHub Release 已发布或远程 CI 已运行。

## 当前交付

- `audioAnalysis`／`audioTimeline` 领域契约、官方 Audio 0.1.0 受限 JavaScript 插件、原生上下 A/B 音频工作台。
- Apple AVFoundation 解码、Accelerate/vDSP 波形与标定 FFT；多声道分析最多八声道，单声道／立体声只读试听。
- 源时间选区、拖拽调整／移动、放大、32 组命名区域、独立试听速度／音高、撤销重做、本机会话恢复。
- 固定 Olaf C helper 生成截取、重排与重复片段候选；独立进程、取消与资源预算，原文件保持只读。
- 私有音频缓存租约；正常结束清理，崩溃遗留可清理，清理不删除其他活跃任务。Full 内嵌插件，同版本 Base 可独立安装。

## 已执行检查

所有测试数据、截图、研究依赖和构建输出都留在项目目录。命令先使用项目环境；脚本内部已加载 `scripts/project-env.sh`。

| 检查 | 结果 |
| --- | --- |
| `bash scripts/check.sh` | 核心比较、编辑、合并、存储、搜索替换回归通过 |
| `bash scripts/tests/check-audio-plugin.sh` | 45 项通过；真实受限 JS、合法与恶意契约、证据保留、范围/覆盖、旧会话兼容 |
| `bash scripts/tests/check-audio-engine.sh` | 43 项通过；正弦幅度/频率、DC/Nyquist、反相声道、瞬态、窗口中心与显示桶、分析预算、重采样与来源保护 |
| `bash scripts/tests/check-audio-playback.sh` | 52 项静音离线检查通过；共用生产 TimePitch 构图，0.5/1/2 倍速 × −12/0/+12 半音九组实测、声道限制、停止/重新准备和来源不变 |
| `bash scripts/tests/check-audio-cache.sh` | 21 项通过；活跃租约、其他进程、崩溃遗留、非本任务文件、符号链接与清理边界 |
| `bash scripts/audio-research/build-matcher.sh` + `python3 scripts/audio-research/check-matcher.py` | 源码哈希核对；8 类匹配行为、短输入、短候选上限、非法 PCM/FIFO、原始文件不变均通过 |
| `bash scripts/tests/check-audio-workflow.sh` | 真实窗口新建、解码、分析、区域保存/恢复、撤销/重做及菜单、实际重排匹配、禁用/重启、Base 安装通过；静音执行 |
| `bash scripts/tests/check-workflow.sh` | 受影响的原生菜单与编辑焦点回归通过；搜索、替换、设置隔离、保存恢复和中英文浅深色/窄窗口通过 |
| Plugin core/runtime/official catalog/manager/archive plugin scripts | 全部通过；core 43 项、catalog 41 项、archive 52 项；受限进程与安装/来源边界回归通过 |
| Photography/API plugin scripts | 35 / 31 项通过 |
| `test_plugin_inventory.py` / `test_github_release.py` | 7 / 19 项通过；Base/Full 内容、独立插件、目录摘要及既有发布保护 |

原生音频窗口首次在工具沙箱内超时，日志显示 macOS 原生服务连接失败；首次结果不计通过。取得工具自动审查授权后，在同一项目内的独立会话完成真实窗口验证。新增菜单测试初次未激活其测试窗口而失败，修正测试激活与等待后，实际菜单命令通过；未放宽产品的焦点隔离。

离线试听测试初次因工具沙箱无法发现 Apple GenericOutput 组件失败；检查程序现先检测组件并明确失败。经自动审查授权运行后，2 秒、1000 Hz 合成音在 0.5/1/2 倍速下测得 4/2/1 秒，−12/0/+12 半音测得 500/1000/2000 Hz。全程手动离线渲染，不连接扬声器；数值通过不代表设备延迟或真实听感已验收。

音频窗口截图保存在 `.build-audio-workflow/renders/`，检查了中文浅色、英文深色、860 点窄窗口、实际频谱和参数浮层。时频图两侧共用最高 24 kHz 的轴，源 Nyquist 以上显示未分析区域，时间标尺避让频率轴；显示像素取覆盖的时间桶/频率 bin 峰值，保留瞬态。平均谱使用线性功率平均，并标注双方实际分析范围。

## 构建与发布审查

`bash scripts/build-app.sh` 已生成 `dist/CrossDiff.app`（Full）；`--edition base --output dist/editions/base/CrossDiff.app` 已生成单独 Base。两者均为 0.11.0 / build 20，`codesign --verify --deep --strict` 通过。Full/Base 的内嵌目录与独立 Audio 包已逐字节核对发行清单。Full 实际含 Archive、PDF、Photography、API、Audio 五个官方插件；Base 仅内嵌 Archive，但保留同样的音频 renderer 和 helper。`python3 scripts/package-audio-plugin.py` 生成 `dist/Plugins/Audio.crossdiffplugin`。

`python3 scripts/audit-publication.py --app dist/CrossDiff.app` 通过，扫描 378 个候选文件与 28 个应用文件，无配置规则命中；`git diff --check` 与本地文档链接检查通过。生产程序不捆绑研究用 Python、JVM 或 FFmpeg。研究原型和实际识别边界见 [M0 记录](audio-matching-m0.md)。本节记录本机验收；后续提交和远端发布检查以 [GitHub Actions](https://github.com/JunyangZhangUSTC/CrossDiff/actions) 的对应运行结果为准。

发布扫描为启发式检查，不能保证不存在任何敏感信息；上游源码合法版权注释中的公开邮箱按精确文件/邮箱白名单保留，其他秘密与个人路径规则继续扫描。

## 尚未完成的验收及产品边界

- 自动独立变速／变调、连续速度变化、混音、精确剪辑边界未交付。Panako 实验只在部分真实案例命中，不是泛化准确率验证。
- STFT 使用 48 kHz 分析副本，每次最多选区前 30 秒，密集参数进一步限制并明确标注范围。不是全长高分辨率谱图缓存。
- 全长波形最多 8192 个包络 bin；深度放大不等于逐采样显示，尚未实现多尺度可见区域重新解码。
- 真实听感、输出设备切换、设备延迟、VoiceOver、拖拽手势的完整人工体验、两小时压力、广泛压缩格式组合、Intel 和 macOS 14 真机尚未验收。
- 匹配评分不是概率，指纹边界不是精确剪辑点；未匹配不能确定为删除。自动结果不写入源音频。

## 文档与发布准备

中英文 README 各新增音频和 API 的真实原生窗口截图，两种外观共八张。示例使用项目内合成音频和 HTTP 记录，音频实际执行分析与重排匹配，不播放声音；API 不发送请求。249 个本地文档链接及图片引用检查通过，截图重现脚本已加入开发指南。发行清单和发布保护的 7／19 项检查通过，同一提交的 Base／Full、独立包、源码与校验和已在本机完整打包（12 个附件）。

首次远端检查使用 macOS 15.7.9 / Swift 6.1.2，发现 API 提示列表的数组拼接表达式超出类型推断时间预算；改为明确类型的逐项追加，保持顺序和去重规则。远端检查、Release 构建与公开发布是独立状态，不能以本机成功替代。

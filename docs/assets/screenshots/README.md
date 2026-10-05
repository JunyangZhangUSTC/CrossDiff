# 原生界面截图 / Native screenshots

这些图片来自 CrossDiff 的真实 macOS 窗口，使用当前比较模型、原生控件与插件完成比较后截图；不是界面设计稿。演示数据全部在项目内生成，不读取个人文件、剪贴板或真实保存的会话，也不播放示例音视频。

These images are captured from actual CrossDiff macOS windows after the production comparison models and plugins have processed generated demo inputs. They are not interface mockups. Rendering never reads personal files, the clipboard or existing user sessions, and never plays the demo media.

- 截图维护日期 / Maintained: **2026-10-05**。
- 源码基线 / Source baseline: `4383bb9`，配合本次更新的截图脚本。
- 覆盖 / Coverage: text, deletion preview, new comparison, folders, archives, images, photography, PDF, Office, API, audio, video, binary / Hex。
- 每个类型包含简体中文、English、浅色和深色版本；文件名采用 `{type}-{zh-CN|en}-{light|dark}.png`。
- 完整窗口通常为 1200 × 790 点；音频与摄影窗口为 1200 × 900 点，以完整展示波形、对应片段和 RGB 图表；新建比较截取原生选择窗口。

## 重现 / Reproduce

在项目根目录、可用的原生 macOS 会话内执行：

```bash
bash scripts/render-readme.sh
```

先编译或复用最近一次隔离构建：

```bash
bash scripts/render-readme.sh --build-only
bash scripts/render-readme.sh --run-only
```

只重拍指定类型，避免重复分析其他素材：

```bash
CROSSDIFF_README_KINDS=folder,photography,office bash scripts/render-readme.sh --run-only
```

构建副本、示例文件、会话与诊断留在 `.build-readme/` 内。全部指定截图生成成功后才复制到当前目录。更改截图 Swift 文件后应重新编译；`--run-only` 使用已有可执行文件。

## 演示素材与路径隐私 / Demo sources and path privacy

`scripts/tests/make-readme-fixtures.py` 生成文件夹、压缩包、Office 和音频输入。`scripts/tests/ReadmeMediaFixtures.swift` 生成原创程序风景、裁剪与色调变体、视频帧和 PDF。风景是确定性的演示插画，不是相机实拍，也不代表真实地点；摄影图表来自 Apple / OpenCV 对这些实际图像的分析。音频对应关系由真实匹配器计算。

`scripts/tests/ReadmeFeatureRenders.swift` 和 `ReadmeRenders.swift` 驱动实际应用生命周期。唯一的显示匿名化位于 `scripts/render-readme.sh`：在隔离源码副本中，把文件夹标题下的 `Text(url.path)` 换为 `Demo/` 加文件夹名称。实际文件路径、比较内容、算法、窗口布局和操作行为保持原样，生产源码未修改。截图不做像素级后期涂改；导出前检查可见辅助功能文字中没有机器专属目录。

The folder header's machine-specific absolute path is replaced with `Demo/` plus the folder name **only in the isolated screenshot source snapshot**. Actual inputs, comparison results, algorithms and native UI layout are unchanged. No production source or captured pixels are edited for anonymization.

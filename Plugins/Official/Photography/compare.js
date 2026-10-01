"use strict";

// The host uses Apple frameworks and OpenCV for decoding, color management and
// histograms. This restricted plugin receives normalized aggregates, never pixels,
// paths, embedded metadata or file access. These findings describe distributions,
// not image quality, scene illumination or a photographer's editing settings.
function photoStatistics(content) {
    if (!content || typeof content.analysisSpace !== "string" || !content.analysisSpace.length ||
        content.analysisSpace.length > 1024 || typeof content.sampled !== "boolean" ||
        !Number.isInteger(content.analyzedPixels) || content.analyzedPixels < 1 || content.analyzedPixels > 100000000 ||
        !Number.isFinite(content.neutralFraction) || content.neutralFraction < 0 || content.neutralFraction > 1) {
        throw new Error("Invalid photography statistics");
    }
    for (const key of ["red", "green", "blue", "lightness", "hue", "saturation"]) {
        const bins = content[key];
        if (!Array.isArray(bins) || bins.length !== (key === "hue" ? 360 : 256) ||
            bins.some(value => !Number.isFinite(value) || value < 0 || value > 1)) {
            throw new Error("Invalid photography histogram");
        }
        const expected = key === "hue" ? 1 - content.neutralFraction : 1;
        if (Math.abs(bins.reduce((total, value) => total + value, 0) - expected) > 0.0001) {
            throw new Error("Invalid photography histogram normalization");
        }
    }
    return content;
}

function share(bins, first, end) {
    return bins.slice(first, end).reduce((total, value) => total + value, 0);
}
function percent(value) { return (100 * value).toFixed(1) + "%"; }
function difference(left, right) {
    const delta = (right - left) * 100;
    // Changes below one percentage point remain an explicit small difference.
    if (Math.abs(delta) < 1) return { zh: "两侧相近（相差不到 1 个百分点）", en: "similar shares (less than 1 percentage point apart)" };
    return { zh: "右侧比左侧" + (delta > 0 ? "多 " : "少 ") + Math.abs(delta).toFixed(1) + " 个百分点",
        en: "right is " + Math.abs(delta).toFixed(1) + " percentage points " + (delta > 0 ? "higher" : "lower") + " than left" };
}
function finding(zhName, enName, left, right) {
    const delta = difference(left, right);
    return { zhHans: zhName + "：左 " + percent(left) + " · 右 " + percent(right) + "；" + delta.zh + "。",
        en: enName + ": left " + percent(left) + " · right " + percent(right) + "; " + delta.en + "." };
}

function compare(request) {
    if (!request || request.protocolVersion !== 1 || request.mode !== "pairwise" ||
        !Array.isArray(request.inputs) || request.inputs.length !== 2) throw new Error("Unsupported photography request");
    const leftInput = request.inputs.find(input => input.role === "left");
    const rightInput = request.inputs.find(input => input.role === "right");
    if (!leftInput || !rightInput) throw new Error("Missing photography inputs");
    const left = photoStatistics(leftInput.content), right = photoStatistics(rightInput.content);
    if (left.analysisSpace !== right.analysisSpace) throw new Error("Different analysis spaces");
    // Fixed equal-width HSL lightness bands on the host's 256-bin SDR histograms.
    // Rounded bin boundaries are stated in the interface; no sensor-clipping claim.
    const findings = [
        finding("低明度区占比（HSL L < 约 1/3）", "Low-lightness share (HSL L < about 1/3)",
            share(left.lightness, 0, 86), share(right.lightness, 0, 86)),
        finding("高明度区占比（HSL L ≥ 约 2/3）", "High-lightness share (HSL L ≥ about 2/3)",
            share(left.lightness, 171, 256), share(right.lightness, 171, 256)),
        finding("高饱和区占比（HSL S ≥ 约 2/3）", "High-saturation share (HSL S ≥ about 2/3)",
            share(left.saturation, 171, 256), share(right.saturation, 171, 256)),
        finding("近中性色占比（HSL S < 0.02）", "Near-neutral share (HSL S < 0.02)", left.neutralFraction, right.neutralFraction)
    ];
    const diagnostics = [{ zhHans: "这些统计描述所选区域在统一 sRGB SDR 分析空间中的分布，不代表曝光设置、调色参数或作品质量。不同构图和主体会影响分布。",
        en: "These statistics describe the selected regions in a common sRGB SDR analysis space, not exposure settings, editing parameters or image quality. Composition and subjects affect distributions." }];
    if (left.sampled || right.sampled) diagnostics.push({ zhHans: "大图采用有界采样分析；图表展示采样像素的分布。", en: "Large images use bounded sampling; charts describe the sampled pixels." });
    return { protocolVersion: 1, runID: request.runID, schema: "crossdiff.photography/1", status: "completed",
        summary: { zhHans: "影调与色彩分布对比", en: "Tone and color distribution comparison" },
        diagnostics: diagnostics, payload: { findings: findings } };
}

"use strict";

// The host supplies bounded metadata and evidence from the native audio engine.
// This restricted plugin never receives PCM, reads files, fingerprints audio,
// starts playback, or turns a raw matching score into a probability.
const AUDIO_MAX_DURATION = 86400;
const AUDIO_METADATA_FIELDS = ["duration", "sampleRate", "channelCount", "frameCount", "format"];

function audioMetadata(value) {
    if (!value || typeof value.id !== "string" || !value.id.length || value.id.length > 128 ||
        typeof value.name !== "string" || value.name.length > 4096 ||
        !Number.isFinite(value.duration) || value.duration <= 0 || value.duration > AUDIO_MAX_DURATION ||
        !Number.isFinite(value.sampleRate) || value.sampleRate < 1000 || value.sampleRate > 768000 ||
        !Number.isInteger(value.channelCount) || value.channelCount < 1 || value.channelCount > 64 ||
        typeof value.frameCount !== "string" || !/^[0-9]{1,20}$/.test(value.frameCount) ||
        typeof value.format !== "string" || !value.format.length || value.format.length > 256) {
        throw new Error("Invalid audio metadata");
    }
    // The 24-hour/sample-rate budget is below Number.MAX_SAFE_INTEGER. The original
    // decimal string is retained when comparing fields and returning evidence.
    const frames = Number(value.frameCount);
    if (!Number.isSafeInteger(frames) || frames <= 0 ||
        Math.abs(frames / value.sampleRate - value.duration) > Math.max(1 / value.sampleRate, 0.000001)) {
        throw new Error("Inconsistent audio frame count");
    }
    return value;
}

function audioRegion(value, duration) {
    if (!value || !Number.isFinite(value.start) || !Number.isFinite(value.end) ||
        value.start < 0 || value.end <= value.start || value.end > duration) {
        throw new Error("Audio region outside its source");
    }
    return value;
}

function audioCorrespondences(values, left, right) {
    if (!Array.isArray(values) || values.length > 512) throw new Error("Audio correspondence limit exceeded");
    const ids = new Set();
    return values.map(value => {
        if (!value || typeof value.id !== "string" || !value.id.length || value.id.length > 128 || ids.has(value.id) ||
            typeof value.method !== "string" || !value.method.length || value.method.length > 256 ||
            !["candidate", "verified", "manual", "rejected"].includes(value.state) ||
            !Number.isFinite(value.rateRatio) || value.rateRatio < 0.05 || value.rateRatio > 20 ||
            (value.pitchSemitones != null && (!Number.isFinite(value.pitchSemitones) || Math.abs(value.pitchSemitones) > 96)) ||
            (value.score != null && (!Number.isFinite(value.score) || value.score < 0 || value.score > 1e12))) {
            throw new Error("Invalid audio correspondence");
        }
        ids.add(value.id);
        audioRegion(value.left, left.duration); audioRegion(value.right, right.duration);
        if (Math.abs((value.right.end - value.right.start) / (value.left.end - value.left.start) - value.rateRatio) > 0.000001) {
            throw new Error("Inconsistent audio time mapping");
        }
        return value;
    });
}

function audioCoveredDuration(regions) {
    if (!regions.length) return 0;
    const sorted = regions.slice().sort((a, b) => a.start - b.start);
    let start = sorted[0].start, end = sorted[0].end, total = 0;
    for (let index = 1; index < sorted.length; index++) {
        if (sorted[index].start <= end) end = Math.max(end, sorted[index].end);
        else { total += end - start; start = sorted[index].start; end = sorted[index].end; }
    }
    return total + end - start;
}

function compare(request) {
    if (!request || request.protocolVersion !== 1 || request.mode !== "pairwise" ||
        !Array.isArray(request.inputs) || request.inputs.length !== 2) throw new Error("Unsupported audio request");
    const leftInput = request.inputs.find(input => input.role === "left");
    const rightInput = request.inputs.find(input => input.role === "right");
    if (!leftInput || !rightInput) throw new Error("Missing audio inputs");
    const left = audioMetadata(leftInput.content), right = audioMetadata(rightInput.content);
    const options = request.options;
    if (!options || !["idle", "running", "complete", "partial", "failed", "cancelled"].includes(options.analysisState) ||
        !Array.isArray(options.diagnostics) || options.diagnostics.length > 64 || options.diagnostics.some(value =>
            !value || typeof value.zhHans !== "string" || !value.zhHans.length || value.zhHans.length > 4096 ||
            typeof value.en !== "string" || !value.en.length || value.en.length > 4096)) {
        throw new Error("Invalid audio analysis state");
    }
    const pairs = audioCorrespondences(options.correspondences, left, right);
    const included = pairs.filter(value => value.state !== "rejected");
    const leftCoverage = audioCoveredDuration(included.map(value => value.left));
    const rightCoverage = audioCoveredDuration(included.map(value => value.right));
    const state = options.analysisState;
    const stateNames = {
        idle: ["尚未查找对应片段", "Matching has not started"],
        running: ["正在查找对应片段", "Finding matching segments"],
        complete: ["对应片段分析已完成", "Segment analysis completed"],
        partial: ["对应片段分析部分完成", "Segment analysis partially completed"],
        failed: ["对应片段分析未完成", "Segment analysis did not complete"],
        cancelled: ["已取消对应片段分析", "Segment analysis cancelled"]
    };
    const summary = included.length ? {
        zhHans: included.length + " 组候选或人工对应 · 左 " + leftCoverage.toFixed(1) + " 秒 · 右 " + rightCoverage.toFixed(1) + " 秒",
        en: included.length + " candidate or manual correspondences · left " + leftCoverage.toFixed(1) + " s · right " + rightCoverage.toFixed(1) + " s"
    } : {
        zhHans: state === "complete" ? "未找到可靠对应片段" : stateNames[state][0],
        en: state === "complete" ? "No reliable corresponding segments found" : stateNames[state][1]
    };
    const diagnostics = options.diagnostics.slice();
    diagnostics.push({
        zhHans: "覆盖时长按两侧区间并集分别计算。原始匹配分数不是概率；未找到对应不代表确定新增或删除。",
        en: "Coverage is the union of ranges on each side. Raw matching scores are not probabilities; unmatched regions are not confirmed additions or deletions."
    });
    return {
        protocolVersion: 1, runID: request.runID, schema: "crossdiff.audio/1",
        status: state === "complete" ? "completed" : "partial", summary: summary, diagnostics: diagnostics,
        payload: { correspondences: pairs, analysisState: state,
            leftCoveredDuration: leftCoverage, rightCoveredDuration: rightCoverage,
            metadataDifferences: AUDIO_METADATA_FIELDS.filter(key => left[key] !== right[key]) }
    };
}

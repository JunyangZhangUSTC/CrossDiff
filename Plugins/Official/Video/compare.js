"use strict";

// The native host owns playback, decoded frames and manual time alignment.
// This JSON-only plugin compares bounded source facts, not visual content.
const VIDEO_METADATA_FIELDS = ["duration", "width", "height", "nominalFrameRate", "codec", "hasAudio", "isHDR"];

function videoKeys(value, expected) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    const keys = Object.keys(value);
    return keys.length === expected.length && keys.every(key => expected.includes(key));
}

function videoMetadata(value) {
    if (!videoKeys(value, VIDEO_METADATA_FIELDS.concat(["id", "name"])) ||
        typeof value.id !== "string" || !value.id.length || value.id.length > 128 ||
        typeof value.name !== "string" || value.name.length > 4096 ||
        !Number.isInteger(value.width) || value.width < 1 || value.width > 32768 ||
        !Number.isInteger(value.height) || value.height < 1 || value.height > 32768 ||
        !Number.isFinite(value.nominalFrameRate) || value.nominalFrameRate < 0 || value.nominalFrameRate > 1000 ||
        typeof value.codec !== "string" || !value.codec.length || value.codec.length > 256 ||
        typeof value.hasAudio !== "boolean" || typeof value.isHDR !== "boolean" ||
        !videoKeys(value.duration, ["value", "timescale"]) ||
        typeof value.duration.value !== "string" || !/^[1-9][0-9]{0,18}$/.test(value.duration.value) ||
        !Number.isInteger(value.duration.timescale) || value.duration.timescale < 1 || value.duration.timescale > 2147483647) {
        throw new Error("Invalid video metadata");
    }
    // All accepted durations fit the 24-hour budget. BigInt preserves exact rational
    // comparisons and never converts a source timestamp to a lossy JSON number.
    if (BigInt(value.duration.value) > 86400n * BigInt(value.duration.timescale)) {
        throw new Error("Video duration exceeds the source-time budget");
    }
    return value;
}

function compare(request) {
    if (!request || request.protocolVersion !== 1 || request.mode !== "pairwise" ||
        typeof request.runID !== "string" || !request.runID.length || request.runID.length > 128 ||
        !Array.isArray(request.inputs) || request.inputs.length !== 2 ||
        !videoKeys(request.options, [])) throw new Error("Unsupported video request");
    const leftInput = request.inputs.find(input => input && input.role === "left");
    const rightInput = request.inputs.find(input => input && input.role === "right");
    if (!leftInput || !rightInput) throw new Error("Missing video inputs");
    const left = videoMetadata(leftInput.content), right = videoMetadata(rightInput.content);
    const fields = VIDEO_METADATA_FIELDS.filter(key => key === "duration"
        ? BigInt(left.duration.value) * BigInt(right.duration.timescale) !== BigInt(right.duration.value) * BigInt(left.duration.timescale)
        : left[key] !== right[key]);
    return {
        protocolVersion: 1, runID: request.runID, schema: "crossdiff.video/1", status: "completed",
        summary: fields.length
            ? { zhHans: fields.length + " 项技术信息不同", en: fields.length + " technical metadata differences" }
            : { zhHans: "所列技术信息一致", en: "Listed technical metadata matches" },
        diagnostics: [{
            zhHans: "技术信息一致不代表画面相同。请查看两侧画面，手动确认内容对应；本结果不包含自动匹配或视频质量评分。",
            en: "Matching metadata does not mean matching pictures. Inspect both sources and confirm content correspondence manually; this result contains no automatic matches or video quality score."
        }],
        payload: { metadataDifferences: fields, contentCompared: false }
    };
}

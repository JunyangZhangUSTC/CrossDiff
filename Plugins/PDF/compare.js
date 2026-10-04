// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 Junyang Zhang
/* CrossDiff PDF comparison, AGPL-3.0-only.
 * Host supplies bounded immutable page descriptors, never file access.
 * Alignment uses text and rendered preview fingerprints. "same" means these
 * representations match, not byte identity or a full-resolution visual proof.
 */
function compare(request) {
    "use strict";
    if (request.protocolVersion !== 1 || request.mode !== "pairwise" || request.inputs.length !== 2) {
        throw new Error("PDF supports exactly two inputs in pairwise mode.");
    }
    const left = request.inputs.find(function (input) { return input.role === "left"; });
    const right = request.inputs.find(function (input) { return input.role === "right"; });
    if (!left || !right) throw new Error("PDF requires left and right input roles.");
    const a = left.content.pages, b = right.content.pages;
    if (!Array.isArray(a) || !Array.isArray(b) || a.length > 200 || b.length > 200) {
        throw new Error("PDF page descriptors exceed the supported limit.");
    }
    function normalized(page) { return page.text.replace(/\s+/g, " ").trim(); }
    function valid(page, index) {
        return page.index === index && typeof page.text === "string" && page.text.length <= 65536 &&
            typeof page.fingerprint === "string" && page.fingerprint.length > 0 &&
            Number.isFinite(page.width) && page.width > 0 && Number.isFinite(page.height) && page.height > 0;
    }
    if (!a.every(valid) || !b.every(valid)) throw new Error("Invalid PDF page descriptor.");
    const na = a.map(normalized), nb = b.map(normalized);
    function previewKey(page) { return JSON.stringify([page.fingerprint, page.width, page.height]); }
    function occurrences(values) {
        const result = new Map();
        values.forEach(function (value, index) {
            if (!result.has(value)) result.set(value, []);
            result.get(value).push(index);
        });
        return result;
    }
    function textEvidence(text, page) {
        // A short heading or an extracted prefix is insufficient evidence of a
        // displaced page. Sample across long pages, not only their shared header.
        const characters = Array.from(text);
        const grams = new Map();
        let total = 0;
        if (page.textTruncated || text.replace(/\s/g, "").length < 40) return { grams: grams, total: total };
        const blockSize = 512, blockCount = characters.length > 4096 ? 8 : 1;
        for (let block = 0; block < blockCount; block++) {
            const start = blockCount === 1 ? 0 : Math.floor(block * (characters.length - blockSize) / (blockCount - 1));
            const end = blockCount === 1 ? characters.length : start + blockSize;
            for (let index = start; index + 3 < end; index++) {
                const gram = characters.slice(index, index + 4).join("");
                grams.set(gram, (grams.get(gram) || 0) + 1); total++;
            }
        }
        // Repetitive filler is not informative even when it is long.
        return grams.size >= 24 ? { grams: grams, total: total } : { grams: new Map(), total: 0 };
    }
    const keysA = a.map(previewKey), keysB = b.map(previewKey);
    const previewsA = occurrences(keysA), previewsB = occurrences(keysB);
    const candidates = [], claimedA = new Set(), claimedB = new Set();
    let ambiguousEvidence = false;
    previewsA.forEach(function (indicesA, key) {
        const indicesB = previewsB.get(key);
        if (!indicesB) return;
        if (indicesA.length !== 1 || indicesB.length !== 1) { ambiguousEvidence = true; return; }
        candidates.push({ left: indicesA[0], right: indicesB[0], strength: 1 });
        claimedA.add(indicesA[0]); claimedB.add(indicesB[0]);
    });
    const evidenceA = na.map(function (text, index) { return textEvidence(text, a[index]); });
    const evidenceB = nb.map(function (text, index) { return textEvidence(text, b[index]); });
    // Accumulate shared features through an inverted index. Unrelated pages
    // need no all-to-all n-gram lookups at the 200-page extraction limit.
    const postings = new Map();
    evidenceB.forEach(function (evidence, index) {
        evidence.grams.forEach(function (count, gram) {
            if (!postings.has(gram)) postings.set(gram, []);
            postings.get(gram).push(index, count);
        });
    });
    const scores = evidenceA.map(function (evidence) {
        const row = new Float64Array(b.length);
        evidence.grams.forEach(function (count, gram) {
            const entries = postings.get(gram);
            if (!entries) return;
            for (let index = 0; index < entries.length; index += 2) row[entries[index]] += Math.min(count, entries[index + 1]);
        });
        for (let j = 0; j < b.length; j++) {
            // Multiplicities matter: a repeated common header must not outweigh
            // the rest of a page simply because its body has fewer distinct grams.
            row[j] = evidence.total && evidenceB[j].total ? 2 * row[j] / (evidence.total + evidenceB[j].total) : 0;
        }
        return row;
    });
    const threshold = 0.78, margin = 0.10;
    for (let i = 0; i < a.length; i++) {
        if (claimedA.has(i)) continue;
        let best = -1, runnerUp = 0;
        for (let j = 0; j < b.length; j++) {
            if (best < 0 || scores[i][j] > scores[i][best]) { runnerUp = best < 0 ? 0 : scores[i][best]; best = j; }
            else runnerUp = Math.max(runnerUp, scores[i][j]);
        }
        if (best < 0 || scores[i][best] < threshold) continue;
        let other = 0;
        for (let k = 0; k < a.length; k++) if (k !== i) other = Math.max(other, scores[k][best]);
        if (claimedB.has(best) || scores[i][best] - runnerUp < margin || scores[i][best] - other < margin) {
            ambiguousEvidence = true; continue;
        }
        candidates.push({ left: i, right: best, strength: scores[i][best] });
    }
    candidates.sort(function (x, y) { return x.left - y.left; });
    // Select a monotonic chain of mutually unique anchors. Unlike an edit-cost
    // alignment, unrelated pages cannot become matches simply to avoid two gaps.
    const chains = [];
    let bestChain = { items: [], strength: 0, ambiguous: false };
    function compareChains(x, y) {
        if (x.items.length !== y.items.length) return x.items.length - y.items.length;
        return Math.abs(x.strength - y.strength) < 1e-8 ? 0 : x.strength - y.strength;
    }
    candidates.forEach(function (candidate, index) {
        let previous = { items: [], strength: 0, ambiguous: false };
        for (let k = 0; k < index; k++) {
            if (candidates[k].right >= candidate.right) continue;
            const order = compareChains(chains[k], previous);
            if (order > 0) previous = chains[k];
            else if (order === 0) previous = { items: previous.items, strength: previous.strength, ambiguous: true };
        }
        const chain = { items: previous.items.concat([candidate]), strength: previous.strength + candidate.strength, ambiguous: previous.ambiguous };
        chains.push(chain);
        const order = compareChains(chain, bestChain);
        if (order > 0) bestChain = chain;
        else if (order === 0) bestChain = { items: bestChain.items, strength: bestChain.strength, ambiguous: true };
    });
    // Multi-page documents require corroboration. A common cover/license page
    // alone must not establish correspondence for an otherwise unrelated work.
    const shorterCount = Math.min(a.length, b.length);
    const required = shorterCount <= 1 ? 1 : Math.max(2, Math.ceil(shorterCount / 2));
    const loneAnchor = shorterCount === 1 && bestChain.items.length === 1 ? bestChain.items[0] : null;
    // The descriptor cannot distinguish a blank-page fingerprint from a useful
    // scan. A lone low-information preview therefore cannot prove a page shift.
    const uncorroboratedShift = loneAnchor && loneAnchor.left !== loneAnchor.right &&
        (!evidenceA[loneAnchor.left].total || !evidenceB[loneAnchor.right].total);
    const supported = bestChain.items.length >= required && !bestChain.ambiguous && !uncorroboratedShift;
    const alignment = { strategy: supported ? "smart" : "pageNumber", reliablePairs: bestChain.items.length };
    if (!supported) alignment.reason = !uncorroboratedShift && (ambiguousEvidence || bestChain.ambiguous || candidates.length >= required) ? "ambiguousEvidence" : "insufficientEvidence";
    const pairs = [];
    function appendPair(i, j) {
        if (i === null) { pairs.push({ left: null, right: j, kind: "added" }); return; }
        if (j === null) { pairs.push({ left: i, right: null, kind: "removed" }); return; }
        const hasText = na[i].length > 0 && nb[j].length > 0;
        const equalPreview = keysA[i] === keysB[j];
        let kind = equalPreview && a[i].text === b[j].text ? "same" : "changed";
        if (!hasText && equalPreview) kind = "unknown";
        if ((a[i].textTruncated || b[j].textTruncated) && kind === "same") kind = "unknown";
        pairs.push({ left: i, right: j, kind: kind });
    }
    let leftIndex = 0, rightIndex = 0;
    function appendGap(leftEnd, rightEnd) {
        while (leftIndex < leftEnd || rightIndex < rightEnd) {
            appendPair(leftIndex < leftEnd ? leftIndex++ : null, rightIndex < rightEnd ? rightIndex++ : null);
        }
    }
    if (supported) bestChain.items.forEach(function (anchor) {
        appendGap(anchor.left, anchor.right);
        appendPair(leftIndex++, rightIndex++);
    });
    appendGap(a.length, b.length);
    const changed = pairs.filter(function (pair) { return pair.kind !== "same" && pair.kind !== "unknown"; }).length;
    const unknown = pairs.filter(function (pair) { return pair.kind === "unknown"; }).length;
    const truncated = Boolean(left.content.truncated || right.content.truncated ||
        a.some(function (page) { return page.textTruncated; }) || b.some(function (page) { return page.textTruncated; }));
    const diagnostics = [{
        zhHans: "页面匹配结合可提取文字与 384 像素页面预览。匹配不代表 PDF 文件字节相同，也不是全分辨率视觉校验。",
        en: "Page alignment uses extractable text and 384-pixel page previews. A match is neither PDF byte identity nor full-resolution visual verification."
    }];
    if (!supported) diagnostics.push(alignment.reason === "ambiguousEvidence" ? {
        zhHans: "页面内容重复或对应关系存在歧义，已按页码比较。单侧页面只表示该页码在另一侧不存在，不能据此认定版本新增或删除。",
        en: "Repeated content or ambiguous correspondence prevents reliable alignment; pages are compared by page number. A one-sided page only means that page number is absent on the other side, not proof of a version insertion or deletion."
    } : {
        zhHans: "没有足够一致且可靠的页面对应证据，已按页码比较。单侧页面只表示该页码在另一侧不存在，不能据此认定版本新增或删除。",
        en: "There is insufficient consistent page evidence for reliable alignment; pages are compared by page number. A one-sided page only means that page number is absent on the other side, not proof of a version insertion or deletion."
    });
    if (supported && pairs.filter(function (pair) { return pair.left !== null && pair.right !== null; }).length > bestChain.items.length) {
        diagnostics.push({
            zhHans: "可靠锚点之间缺少明确对应证据的页面按相对顺序对照；这些页面仍需人工核对，可使用手动配对。",
            en: "Pages without decisive evidence between reliable anchors are compared in relative order; review these pages and use manual pairing when needed."
        });
    }
    if (a.some(function (p) { return !normalized(p); }) || b.some(function (p) { return !normalized(p); })) {
        diagnostics.push({ zhHans: "部分页面没有可提取文字，可能是扫描页或空白页；未执行 OCR。", en: "Some pages have no extractable text and may be scanned or blank. OCR was not performed." });
    }
    if (truncated) diagnostics.push({ zhHans: "页面或文字达到读取上限；结果仅覆盖已读取部分。", en: "Page or text limits were reached. Results cover only the content read." });
    return {
        protocolVersion: 1, runID: request.runID, schema: "crossdiff.document-pages/1",
        status: truncated ? "partial" : "completed",
        summary: { zhHans: changed + " 组页面有变化" + (unknown ? " · " + unknown + " 组需查看页面" : ""),
                   en: changed + " changed page pairs" + (unknown ? " · " + unknown + " require page review" : "") },
        diagnostics: diagnostics, payload: { pairs: pairs, alignment: alignment }
    };
}

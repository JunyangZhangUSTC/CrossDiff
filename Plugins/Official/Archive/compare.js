"use strict";

function archiveRequire(condition, field) {
    if (!condition) throw new Error(`Invalid archive catalog: ${field}`);
}

function archiveUTF8Bytes(value) {
    archiveRequire(typeof value === "string", "string");
    let bytes = 0;
    for (let index = 0; index < value.length; index++) {
        const unit = value.charCodeAt(index);
        if (unit >= 0xd800 && unit <= 0xdbff) {
            const next = value.charCodeAt(++index);
            archiveRequire(next >= 0xdc00 && next <= 0xdfff, "Unicode surrogate");
            bytes += 4;
        } else {
            archiveRequire(unit < 0xdc00 || unit > 0xdfff, "Unicode surrogate");
            bytes += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
        }
    }
    return bytes;
}

function archiveCatalog(content) {
    archiveRequire(content && typeof content.listingComplete === "boolean"
        && Array.isArray(content.entries) && content.entries.length <= 10000, "listing / entries limit");
    const entries = new Map();
    for (const entry of content.entries) {
        archiveRequire(entry && typeof entry === "object" && !Array.isArray(entry), "entry");
        const path = entry.path;
        archiveRequire(archiveUTF8Bytes(path) <= 4096 && path.length > 0 && entry.id === path
            && !path.includes("\0") && !path.includes("\\") && !/^[a-zA-Z]:/.test(path), "path / id");
        const components = path.split("/");
        archiveRequire(components.length <= 128 && components.every(part => part && part !== "." && part !== ".."), "path components");
        const key = path.normalize("NFC");
        archiveRequire(!entries.has(key), "duplicate canonical path");
        archiveRequire(["file", "directory", "symbolicLink", "hardLink", "other"].includes(entry.kind), "kind");
        archiveRequire(["verified", "unverified"].includes(entry.contentState), "contentState");
        archiveRequire(entry.size === null || (Number.isSafeInteger(entry.size) && entry.size >= 0), "size");
        archiveRequire(entry.sha256 === null || (typeof entry.sha256 === "string" && /^[a-f0-9]{64}$/.test(entry.sha256)), "sha256");
        if (entry.kind === "directory") archiveRequire(entry.size === 0 && entry.sha256 === null, "directory metadata");
        else if (entry.kind === "file" && entry.contentState === "verified") {
            archiveRequire(entry.size !== null && entry.sha256 !== null, "verified file metadata");
        } else if (entry.kind !== "file") {
            archiveRequire(entry.contentState === "unverified" && entry.sha256 === null, "non-regular content");
        }
        entries.set(key, entry);
    }
    for (const path of entries.keys()) {
        const slash = path.lastIndexOf("/");
        if (slash >= 0) archiveRequire(entries.get(path.slice(0, slash))?.kind === "directory", "ancestor directory");
    }
    return entries;
}

// Catalog identifiers are data only: this algorithm has no filesystem or network API.
function compare(request) {
    archiveRequire(request && request.protocolVersion === 1 && request.mode === "pairwise", "protocol / mode");
    archiveRequire(archiveUTF8Bytes(request.runID) > 0 && archiveUTF8Bytes(request.runID) <= 128, "runID");
    archiveRequire(Array.isArray(request.inputs) && request.inputs.length === 2, "inputs");
    for (const input of request.inputs) {
        archiveRequire(input && archiveUTF8Bytes(input.id) > 0 && archiveUTF8Bytes(input.id) <= 128
            && archiveUTF8Bytes(input.name) <= 4096, "input identity");
    }
    const leftInput = request.inputs.find(input => input.role === "left");
    const rightInput = request.inputs.find(input => input.role === "right");
    archiveRequire(leftInput && rightInput && leftInput.id !== rightInput.id, "left / right roles");
    // Swift String also treats canonically equivalent paths as equal. Preserve raw IDs in results.
    const left = archiveCatalog(leftInput.content);
    const right = archiveCatalog(rightInput.content);
    const paths = Array.from(new Set([...left.keys(), ...right.keys()])).sort();
    const pairs = paths.map(path => {
        const l = left.get(path), r = right.get(path);
        let state;
        if ((l && l.contentState !== "verified") || (r && r.contentState !== "verified")) state = "unknown";
        else if (!l) state = leftInput.content.listingComplete ? "added" : "unknown";
        else if (!r) state = rightInput.content.listingComplete ? "removed" : "unknown";
        else if (l.kind !== r.kind) state = "typeChanged";
        else if (l.kind === "directory") state = "same";
        else state = l.size === r.size && l.sha256 === r.sha256 ? "same" : "changed";
        return {left: l ? l.id : null, right: r ? r.id : null, state};
    });
    const rows = new Map(paths.map((path, index) => [path, pairs[index]]));
    // Process descendants first so an unknown or changed child reaches every ancestor.
    for (const path of paths.slice().sort((a, b) => b.length - a.length)) {
        const slash = path.lastIndexOf("/");
        if (slash < 0) continue;
        const parent = path.slice(0, slash);
        if (left.get(parent)?.kind !== "directory" || right.get(parent)?.kind !== "directory") continue;
        const row = rows.get(path), parentRow = rows.get(parent);
        if (row.state === "unknown") parentRow.state = "unknown";
        else if (row.state !== "same" && parentRow.state !== "unknown") parentRow.state = "changed";
    }
    const cohorts = new Map();
    for (const [side, entries] of [["left", left], ["right", right]]) {
        for (const path of paths) {
            const entry = entries.get(path);
            if (!entry || entry.kind !== "file" || entry.contentState !== "verified") continue;
            const key = `${entry.size}:${entry.sha256}`;
            if (!cohorts.has(key)) cohorts.set(key, {left: [], right: [], paths: new Set()});
            const cohort = cohorts.get(key);
            cohort[side].push(entry.id);
            cohort.paths.add(path);
        }
    }
    const sameContentGroups = Array.from(cohorts.keys()).sort().flatMap(key => {
        const cohort = cohorts.get(key);
        return cohort.left.length && cohort.right.length && cohort.paths.size >= 2
            ? [{left: cohort.left, right: cohort.right}] : [];
    });
    const partial = pairs.some(pair => pair.state === "unknown") || !leftInput.content.listingComplete || !rightInput.content.listingComplete;
    return {
        protocolVersion: request.protocolVersion,
        runID: request.runID,
        schema: "crossdiff.archive-tree/1",
        status: partial ? "partial" : "completed",
        summary: {zhHans: `已比较 ${pairs.length} 个虚拟路径。`, en: `Compared ${pairs.length} virtual paths.`},
        diagnostics: partial ? [{zhHans: "部分条目未验证，不能判断为相同。", en: "Some entries are unverified and cannot be considered identical."}] : [],
        payload: {pairs, sameContentGroups}
    };
}

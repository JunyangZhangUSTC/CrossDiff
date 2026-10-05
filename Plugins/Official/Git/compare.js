"use strict";

// Per helper invocation only. The native host batches a repository without a total file cap.
const GIT_BATCH_ENTRIES = 128;

// No process, filesystem, network or credential APIs are exposed to this algorithm.
function gitRequire(condition, field) {
    if (!condition) throw new Error(`Invalid Git comparison: ${field}`);
}
function gitBytes(value) {
    gitRequire(typeof value === "string", "string");
    let count = 0;
    for (let index = 0; index < value.length; index++) {
        const unit = value.charCodeAt(index);
        if (unit >= 0xd800 && unit <= 0xdbff) {
            const next = value.charCodeAt(++index);
            gitRequire(next >= 0xdc00 && next <= 0xdfff, "Unicode surrogate"); count += 4;
        } else {
            gitRequire(unit < 0xdc00 || unit > 0xdfff, "Unicode surrogate");
            count += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
        }
    }
    return count;
}
function gitPath(path) {
    const components = typeof path === "string" ? path.split("/") : [];
    return components.length > 0 && gitBytes(path) <= 4096 && !path.includes("\0")
        && components.length <= 128 && components.every(part => part && part !== "." && part !== "..");
}
function gitObjectID(value) { return typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value); }
function gitKind(mode) { return mode === "100755" ? "100644" : mode; }
function gitKeys(value, expected) {
    const actual = Object.keys(value).sort();
    return actual.length === expected.length && actual.every((key, index) => key === expected.slice().sort()[index]);
}
function gitCatalog(value) {
    gitRequire(value && typeof value === "object" && !Array.isArray(value)
        && Array.isArray(value.entries) && value.entries.length <= GIT_BATCH_ENTRIES, "tree");
    let snapshot;
    if (value.source === undefined) {
        gitRequire(gitKeys(value, ["commit", "entries"]) && gitObjectID(value.commit), "commit source");
        snapshot = {source: "commit", snapshot: `commit:${value.commit}`, commit: value.commit, emptyBaseline: false};
    } else {
        gitRequire(gitKeys(value, ["source", "snapshot", "commit", "emptyBaseline", "entries"])
            && ["commit", "index", "workingTree"].includes(value.source)
            && gitBytes(value.snapshot) > 0 && gitBytes(value.snapshot) <= 256
            && !/[\u0000-\u001f\u007f]/.test(value.snapshot)
            && (value.commit === null || typeof value.commit === "string")
            && typeof value.emptyBaseline === "boolean", "snapshot metadata");
        if (value.source === "commit") {
            gitRequire(value.emptyBaseline ? value.commit === null && value.entries.length === 0
                : gitObjectID(value.commit), "commit / empty baseline");
        } else gitRequire(value.commit === null && !value.emptyBaseline, "local source is not a commit");
        snapshot = {source: value.source, snapshot: value.snapshot, commit: value.commit, emptyBaseline: value.emptyBaseline};
    }
    let objectIDLength = snapshot.commit === null ? null : snapshot.commit.length;
    const result = new Map();
    for (const entry of value.entries) {
        gitRequire(entry && gitPath(entry.path) && gitObjectID(entry.objectID)
            && (objectIDLength === null || entry.objectID.length === objectIDLength)
            && ["100644", "100755", "120000", "160000"].includes(entry.mode), "tree entry");
        objectIDLength = entry.objectID.length;
        // Git paths are byte identities, including canonically distinct Unicode names.
        gitRequire(!result.has(entry.path), "duplicate path");
        result.set(entry.path, entry);
    }
    for (const entry of result.values()) {
        const components = entry.path.split("/");
        for (let index = 1; index < components.length; index++) {
            gitRequire(!result.has(components.slice(0, index).join("/")), "file ancestor");
        }
    }
    return {entries: result, snapshot, objectIDLength};
}
function compare(request) {
    gitRequire(request && request.protocolVersion === 1 && request.mode === "pairwise"
        && gitBytes(request.runID) > 0 && gitBytes(request.runID) <= 128, "protocol / runID");
    gitRequire(Array.isArray(request.inputs) && request.inputs.length === 2, "inputs");
    const leftInput = request.inputs.find(input => input.role === "left");
    const rightInput = request.inputs.find(input => input.role === "right");
    gitRequire(leftInput && rightInput && leftInput.id !== rightInput.id, "pairwise sources");
    for (const input of request.inputs) gitRequire(gitBytes(input.id) > 0 && gitBytes(input.id) <= 128 && gitBytes(input.name) <= 4096, "input identity");
    const leftCatalog = gitCatalog(leftInput.content), rightCatalog = gitCatalog(rightInput.content);
    const left = leftCatalog.entries, right = rightCatalog.entries;
    gitRequire(leftCatalog.objectIDLength === null || rightCatalog.objectIDLength === null
        || leftCatalog.objectIDLength === rightCatalog.objectIDLength, "object formats");
    const options = request.options || {};
    gitRequire(Object.keys(options).every(key => key === "renameHints"), "options");
    const hints = options.renameHints === undefined ? [] : options.renameHints;
    gitRequire(Array.isArray(hints) && hints.length <= GIT_BATCH_ENTRIES, "rename hints");
    const renames = new Map(), destinations = new Set();
    for (const hint of hints) {
        gitRequire(hint && left.has(hint.left) && right.has(hint.right) && hint.left !== hint.right
            && !right.has(hint.left) && !left.has(hint.right)
            && gitKind(left.get(hint.left).mode) === gitKind(right.get(hint.right).mode)
            && !renames.has(hint.left) && !destinations.has(hint.right), "rename sources");
        renames.set(hint.left, hint.right); destinations.add(hint.right);
    }
    const rows = [];
    for (const path of new Set([...left.keys(), ...right.keys()])) {
        if (destinations.has(path)) continue;
        const l = left.get(path), r = right.get(renames.get(path) || path);
        let state;
        if (renames.has(path)) state = "renamed";
        else if (!l) state = "added";
        else if (!r) state = "deleted";
        else if (gitKind(l.mode) !== gitKind(r.mode)) state = "typeChanged";
        else if (l.objectID !== r.objectID || l.mode !== r.mode) state = "modified";
        else state = "unchanged";
        rows.push({left: l ? l.path : null, right: r ? r.path : null, state});
    }
    rows.sort((a, b) => {
        const l = a.right || a.left, r = b.right || b.left;
        return l < r ? -1 : l > r ? 1 : 0;
    });
    const counts = {unchanged: 0, added: 0, deleted: 0, modified: 0, renamed: 0, typeChanged: 0};
    for (const row of rows) counts[row.state]++;
    const changes = rows.length - counts.unchanged;
    return {protocolVersion: 1, runID: request.runID, schema: "crossdiff.git-tree/1", status: "completed",
        summary: {zhHans: `${rows.length} 个文件中有 ${changes} 项变化。`, en: `${changes} changes across ${rows.length} files.`},
        diagnostics: [], payload: {rows, counts, snapshots: {left: leftCatalog.snapshot, right: rightCatalog.snapshot}}};
}

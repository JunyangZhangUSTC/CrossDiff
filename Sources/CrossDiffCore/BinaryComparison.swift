import Foundation

public enum BinaryChangeKind: String, Sendable { case equal, changed, added, removed }

public struct BinarySpan: Sendable, Equatable {
    public let kind: BinaryChangeKind
    public let leftOffset: Int64
    public let rightOffset: Int64
    public let leftCount: Int64
    public let rightCount: Int64
    public init(kind: BinaryChangeKind, leftOffset: Int64, rightOffset: Int64, leftCount: Int64, rightCount: Int64) {
        self.kind = kind; self.leftOffset = leftOffset; self.rightOffset = rightOffset
        self.leftCount = leftCount; self.rightCount = rightCount
    }
}

public struct BinaryComparisonResult: Sendable {
    public let spans: [BinarySpan]
    public let leftSize: Int64
    public let rightSize: Int64
    public let alignmentIsApproximate: Bool
    public init(spans: [BinarySpan], leftSize: Int64, rightSize: Int64, alignmentIsApproximate: Bool) {
        self.spans = spans; self.leftSize = leftSize; self.rightSize = rightSize
        self.alignmentIsApproximate = alignmentIsApproximate
    }
    public var changeIndices: [Int] { spans.indices.filter { spans[$0].kind != .equal } }
}

public enum BinaryDiffEngine {
    public static let maximumComparisonBytes: Int64 = 8 * 1024 * 1024 * 1024

    private static let localLimit = 1024
    private static let maximumSpans = 16_384
    private static let maximumEditCells = 16 * 1024 * 1024
    private static let anchorWindow = 64 * 1024 + 16
    private static let maximumAnchorBytes = 16 * 1024 * 1024

    public static func compare(left: BinaryFileSource, right: BinaryFileSource,
                               progress: @Sendable (Double) -> Void = { _ in }) throws -> BinaryComparisonResult {
        try Task.checkCancellation()
        guard left.size <= maximumComparisonBytes, right.size <= maximumComparisonBytes else { throw BinaryFileError.comparisonTooLarge }
        try left.verifyUnchanged(); try right.verifyUnchanged()
        var spans: [BinarySpan] = [], l: Int64 = 0, r: Int64 = 0
        var approximate = false, editBudget = maximumEditCells, anchorBudget = maximumAnchorBytes
        var leftWindow = ReadWindow(source: left), rightWindow = ReadWindow(source: right)
        progress(0)
        while l < left.size || r < right.size {
            try Task.checkCancellation()
            defer { progress(Double(l + r) / Double(max(1, left.size + right.size))) }
            if l == left.size || r == right.size {
                append(l == left.size ? .added : .removed, left.size - l, right.size - r, spans: &spans, left: &l, right: &r)
                continue
            }
            if spans.count >= maximumSpans - 2 * localLimit - 1 || editBudget <= 0 {
                approximate = true
                append(.changed, left.size - l, right.size - r, spans: &spans, left: &l, right: &r)
                break
            }
            let a = try leftWindow.read(at: l)
            let b = try rightWindow.read(at: r)
            if a == b {
                append(.equal, Int64(a.count), Int64(b.count), spans: &spans, left: &l, right: &r)
                continue
            }
            let prefix = try equalPrefix(a, b)
            if prefix > 0 {
                append(.equal, Int64(prefix), Int64(prefix), spans: &spans, left: &l, right: &r)
                continue
            }
            if left.size - l <= localLimit, right.size - r <= localLimit {
                let cells = (a.count + 1) * (b.count + 1)
                if cells <= editBudget {
                    editBudget -= cells
                    for kind in try localEdits(Array(a), Array(b)) {
                        append(kind, kind == .added ? 0 : 1, kind == .removed ? 0 : 1, spans: &spans, left: &l, right: &r)
                    }
                    continue
                }
            }
            if anchorBudget <= 0 {
                approximate = true
                append(.changed, left.size - l, right.size - r, spans: &spans, left: &l, right: &r)
                break
            }
            // Prefer a small neighborhood for sparse byte edits. Only a failed
            // local search pays for the 64 KiB lookahead plus its 16-byte anchor.
            var windowA = Array(a.prefix(2048)), windowB = Array(b.prefix(2048))
            guard windowA.count + windowB.count <= anchorBudget else {
                approximate = true
                append(.changed, left.size - l, right.size - r, spans: &spans, left: &l, right: &r)
                break
            }
            anchorBudget -= windowA.count + windowB.count
            var anchor = try resynchronize(windowA, windowB)
            if anchor == nil, max(a.count, b.count) > 2048 {
                windowA = Array(a.prefix(anchorWindow)); windowB = Array(b.prefix(anchorWindow))
                guard windowA.count + windowB.count <= anchorBudget else {
                    approximate = true
                    append(.changed, left.size - l, right.size - r, spans: &spans, left: &l, right: &r)
                    break
                }
                anchorBudget -= windowA.count + windowB.count
                anchor = try resynchronize(windowA, windowB)
            }
            if let anchor {
                if anchor.left == 0 || anchor.right == 0 {
                    append(anchor.left == 0 ? .added : .removed, Int64(anchor.left), Int64(anchor.right), spans: &spans, left: &l, right: &r)
                } else if anchor.left <= localLimit, anchor.right <= localLimit,
                          (anchor.left + 1) * (anchor.right + 1) <= editBudget {
                    editBudget -= (anchor.left + 1) * (anchor.right + 1)
                    for kind in try localEdits(Array(windowA.prefix(anchor.left)), Array(windowB.prefix(anchor.right))) {
                        append(kind, kind == .added ? 0 : 1, kind == .removed ? 0 : 1, spans: &spans, left: &l, right: &r)
                    }
                } else {
                    approximate = true
                    append(.changed, Int64(anchor.left), Int64(anchor.right), spans: &spans, left: &l, right: &r)
                }
                append(.equal, Int64(anchor.length), Int64(anchor.length), spans: &spans, left: &l, right: &r)
            } else {
                // Unmatched windows are explicitly coarse. Subsequent windows may
                // recover alignment; after the fixed work budget the rest is coarse.
                approximate = true
                append(.changed, Int64(windowA.count), Int64(windowB.count), spans: &spans, left: &l, right: &r)
            }
        }
        try left.verifyUnchanged(); try right.verifyUnchanged(); try Task.checkCancellation(); progress(1)
        return BinaryComparisonResult(spans: spans, leftSize: left.size, rightSize: right.size, alignmentIsApproximate: approximate)
    }

    /// Two rolling one-MiB buffers avoid rereading a large block for each tiny
    /// edit. Slices share the bounded allocation. Near a boundary, refill early
    /// so the entire resynchronization lookahead remains available.
    private struct ReadWindow {
        let source: BinaryFileSource
        private var offset: Int64 = 0
        private var data = Data()
        init(source: BinaryFileSource) { self.source = source }
        mutating func read(at position: Int64) throws -> Data {
            let needed = min(Int64(anchorWindow), source.size - position)
            if position >= offset, position - offset <= Int64(data.count),
               Int64(data.count) - (position - offset) >= needed {
                try source.verifyUnchanged()
                let start = data.startIndex + Int(position - offset)
                return data[start..<data.endIndex]
            }
            data = try source.read(offset: position, count: Int(min(Int64(BinaryFileSource.maximumReadBytes), source.size - position)))
            offset = position
            return data
        }
    }

    private static func equalPrefix(_ a: Data, _ b: Data) throws -> Int {
        try a.withUnsafeBytes { lhs in
            try b.withUnsafeBytes { rhs in
                let left = lhs.bindMemory(to: UInt8.self), right = rhs.bindMemory(to: UInt8.self)
                var index = 0
                while index < min(a.count, b.count), left[index] == right[index] {
                    if index & 0xffff == 0 { try Task.checkCancellation() }
                    index += 1
                }
                return index
            }
        }
    }

    /// Nearest monotone 16-byte anchor in a bounded window. Hashes only find
    /// candidates; actual byte equality is mandatory. This is local alignment,
    /// not a claim of a globally minimal edit script for arbitrary binary files.
    private static func resynchronize(_ a: [UInt8], _ b: [UInt8]) throws -> (left: Int, right: Int, length: Int)? {
        let length = min(16, min(a.count, b.count))
        guard length >= 4 else { return nil }
        let base: UInt64 = 257
        var factor: UInt64 = 1
        for _ in 1..<length { factor = factor &* base }
        func initialHash(_ bytes: [UInt8]) -> UInt64 {
            bytes.prefix(length).reduce(UInt64(0)) { ($0 &* base) &+ UInt64($1) }
        }
        var positions: [UInt64: Int] = [:]
        positions.reserveCapacity(a.count - length + 1)
        var hash = initialHash(a)
        for index in 0...(a.count - length) {
            if index & 0xfff == 0 { try Task.checkCancellation() }
            // Earliest occurrence gives the smallest combined forward distance.
            if positions[hash] == nil { positions[hash] = index }
            if index + length < a.count {
                hash = ((hash &- (UInt64(a[index]) &* factor)) &* base) &+ UInt64(a[index + length])
            }
        }
        var best: (left: Int, right: Int, length: Int)?
        hash = initialHash(b)
        for index in 0...(b.count - length) {
            if index & 0xfff == 0 { try Task.checkCancellation() }
            if let best, index > best.left + best.right { break }
            if let candidate = positions[hash], candidate + index > 0,
               (best == nil || candidate + index < best!.left + best!.right),
               a[candidate..<(candidate + length)].elementsEqual(b[index..<(index + length)]) {
                best = (candidate, index, length)
            }
            if index + length < b.count {
                hash = ((hash &- (UInt64(b[index]) &* factor)) &* base) &+ UInt64(b[index + length])
            }
        }
        return best
    }

    /// Exact unit-cost edit alignment inside a bounded gap. Two distance rows
    /// and one byte per traceback cell keep storage independent of file size.
    private static func localEdits(_ a: [UInt8], _ b: [UInt8]) throws -> [BinaryChangeKind] {
        let width = b.count + 1
        var previous = (0...b.count).map(UInt16.init), current = previous
        var directions = [UInt8](repeating: 0, count: (a.count + 1) * width)
        if !a.isEmpty {
            for i in 1...a.count {
                try Task.checkCancellation()
                current[0] = UInt16(i)
                if !b.isEmpty {
                    for j in 1...b.count {
                        var distance = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                        var direction: UInt8 = 0
                        if previous[j] + 1 < distance { distance = previous[j] + 1; direction = 1 }
                        if current[j - 1] + 1 < distance { distance = current[j - 1] + 1; direction = 2 }
                        current[j] = distance; directions[i * width + j] = direction
                    }
                }
                swap(&previous, &current)
            }
        }
        var i = a.count, j = b.count, edits: [BinaryChangeKind] = []
        while i > 0 || j > 0 {
            if i == 0 { edits.append(.added); j -= 1 }
            else if j == 0 { edits.append(.removed); i -= 1 }
            else if directions[i * width + j] == 1 { edits.append(.removed); i -= 1 }
            else if directions[i * width + j] == 2 { edits.append(.added); j -= 1 }
            else { edits.append(a[i - 1] == b[j - 1] ? .equal : .changed); i -= 1; j -= 1 }
        }
        return edits.reversed()
    }

    private static func append(_ kind: BinaryChangeKind, _ lc: Int64, _ rc: Int64,
                               spans: inout [BinarySpan], left: inout Int64, right: inout Int64) {
        guard lc != 0 || rc != 0 else { return }
        if let last = spans.last, last.kind == kind {
            spans[spans.count - 1] = BinarySpan(kind: kind, leftOffset: last.leftOffset, rightOffset: last.rightOffset,
                                              leftCount: last.leftCount + lc, rightCount: last.rightCount + rc)
        } else { spans.append(BinarySpan(kind: kind, leftOffset: left, rightOffset: right, leftCount: lc, rightCount: rc)) }
        left += lc; right += rc
    }
}

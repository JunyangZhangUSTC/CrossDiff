import Foundation
import Darwin
import CrossDiffCore

@main enum BinaryCoreChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func validate(_ result: BinaryComparisonResult, left: Data, right: Data) throws {
        var l = 0, r = 0, reconstructed = Data()
        var previous: BinaryChangeKind?
        for span in result.spans {
            guard span.leftOffset == Int64(l), span.rightOffset == Int64(r), span.leftCount >= 0, span.rightCount >= 0,
                  span.leftCount + span.rightCount > 0, span.kind != previous else { throw Failure(description: "span coverage is not monotone/coalesced") }
            let lc = Int(span.leftCount), rc = Int(span.rightCount)
            guard l + lc <= left.count, r + rc <= right.count else { throw Failure(description: "span exceeds source bytes") }
            switch span.kind {
            case .equal:
                guard lc == rc, left[l..<(l + lc)] == right[r..<(r + rc)] else { throw Failure(description: "equal span contains unequal bytes") }
                reconstructed.append(left[l..<(l + lc)])
            case .changed:
                guard lc > 0, rc > 0 else { throw Failure(description: "changed span needs both sides") }
                reconstructed.append(right[r..<(r + rc)])
            case .added:
                guard lc == 0, rc > 0 else { throw Failure(description: "addition has invalid counts") }
                reconstructed.append(right[r..<(r + rc)])
            case .removed:
                guard rc == 0, lc > 0 else { throw Failure(description: "removal has invalid counts") }
            }
            l += lc; r += rc; previous = span.kind
        }
        try expect(l == left.count && r == right.count && result.leftSize == Int64(l) && result.rightSize == Int64(r) && reconstructed == right,
                   "spans cover both originals and reconstruct the entire right input")
    }
    static func main() async {
        do { try await run(); print("PASS: \(count) binary core checks") }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftURL = root.appendingPathComponent("left.bin"), rightURL = root.appendingPathComponent("right.bin")
        func compare(_ left: Data, _ right: Data) throws -> BinaryComparisonResult {
            try left.write(to: leftURL); try right.write(to: rightURL)
            return try BinaryDiffEngine.compare(left: BinaryFileSource(url: leftURL), right: BinaryFileSource(url: rightURL))
        }
        let empty = try compare(Data(), Data())
        try expect(empty.spans.isEmpty && empty.leftSize == 0 && empty.rightSize == 0, "two empty files have no changes")
        let allAdded = try compare(Data(), Data([0, 0xff]))
        try validate(allAdded, left: Data(), right: Data([0, 0xff]))
        try expect(allAdded.spans.map(\.kind) == [.added], "an empty left file makes the entire right input an addition")
        let allRemoved = try compare(Data([0, 0xff]), Data())
        try validate(allRemoved, left: Data([0, 0xff]), right: Data())
        try expect(allRemoved.spans.map(\.kind) == [.removed], "an empty right file makes the entire left input a removal")

        let bytes = Data([0, 0xff, 0x7f, 0x20, 0x41])
        let equal = try compare(bytes, bytes)
        try expect(equal.spans == [BinarySpan(kind: .equal, leftOffset: 0, rightOffset: 0, leftCount: 5, rightCount: 5)], "identical raw bytes form one confirmed equal span")
        try expect(!equal.alignmentIsApproximate && equal.changeIndices.isEmpty, "equal comparison has exact coverage and no navigation changes")
        let inserted = try compare(Data([1, 2, 3, 4]), Data([1, 2, 99, 3, 4]))
        try expect(inserted.spans == [
            BinarySpan(kind: .equal, leftOffset: 0, rightOffset: 0, leftCount: 2, rightCount: 2),
            BinarySpan(kind: .added, leftOffset: 2, rightOffset: 2, leftCount: 0, rightCount: 1),
            BinarySpan(kind: .equal, leftOffset: 2, rightOffset: 3, leftCount: 2, rightCount: 2)], "one inserted byte must align the following suffix")
        try expect(!inserted.alignmentIsApproximate, "small insertion is not a coarse fallback")
        let modified = try compare(Data([1, 2, 3]), Data([1, 9, 3]))
        try expect(modified.spans.map(\.kind) == [.equal, .changed, .equal], "a byte replacement retains surrounding equal spans")
        var seed: UInt64 = 0x9e3779b97f4a7c15
        func randomByte() -> UInt8 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        let long = Data((0..<(2 * 1024 * 1024 + 33)).map { _ in randomByte() })
        let blockBoundary = 1024 * 1024
        let insertionOffsets: [Int] = [0, 16, blockBoundary - 8, blockBoundary, blockBoundary + 8, long.count - 8]
        for offset in insertionOffsets {
            var added = long
            added.insert(contentsOf: [0xff, 0x09, 0x80], at: offset)
            let alignment = try compare(long, added)
            try validate(alignment, left: long, right: added)
            try expect(!alignment.alignmentIsApproximate && alignment.spans.filter { $0.kind == .added }.reduce(0) { $0 + $1.rightCount } == 3 && alignment.spans.allSatisfy { $0.kind == .equal || $0.kind == .added }, "insertions at start, row/chunk seams and end resynchronize")
            let deletion = try compare(added, long)
            try validate(deletion, left: added, right: long)
            try expect(deletion.spans.allSatisfy { $0.kind == .equal || $0.kind == .removed }, "deletion restores the original alignment")
        }
        var chunkInserted = long
        chunkInserted.insert(contentsOf: Data(repeating: 0xfe, count: 64 * 1024), at: 1024 * 1024)
        let chunkInsertion = try compare(long, chunkInserted)
        try validate(chunkInsertion, left: long, right: chunkInserted)
        try expect(!chunkInsertion.alignmentIsApproximate && chunkInsertion.spans.filter { $0.kind == .added }.reduce(0) { $0 + $1.rightCount } == 64 * 1024 && chunkInsertion.spans.allSatisfy { $0.kind == .equal || $0.kind == .added },
                   "a full 64 KiB insertion retains the anchor beyond the inserted chunk")
        let chunkDeletion = try compare(chunkInserted, long)
        try validate(chunkDeletion, left: chunkInserted, right: long)
        try expect(!chunkDeletion.alignmentIsApproximate && chunkDeletion.spans.allSatisfy { $0.kind == .equal || $0.kind == .removed },
                   "a full 64 KiB deletion resynchronizes beyond the removed chunk")
        var densePrefix = long
        for index in stride(from: 0, to: 64 * 1024, by: 128) { densePrefix[index] ^= 0xff }
        let densePrefixResult = try compare(long, densePrefix)
        try validate(densePrefixResult, left: long, right: densePrefix)
        try expect(!densePrefixResult.alignmentIsApproximate && densePrefixResult.spans.filter { $0.kind == .equal }.reduce(0) { $0 + $1.leftCount } == long.count - 512,
                   "small regularly spaced edits in a short prefix do not exhaust large-window work budgets")
        for offset in [0, 16, 1024, 4096] {
            let repeated = Data(repeating: 0x41, count: 4096)
            var added = repeated; added.insert(0x42, at: offset)
            let result = try compare(repeated, added)
            try validate(result, left: repeated, right: added)
            try expect(result.spans.filter { $0.kind == .added }.reduce(0) { $0 + $1.rightCount } == 1 && !result.alignmentIsApproximate,
                       "repeated bytes retain a single inserted distinct byte")
        }
        for _ in 0..<200 {
            let original = Data((0..<Int(randomByte())).map { _ in randomByte() })
            var edited = original
            let operations = 1 + Int(randomByte() % 8)
            for _ in 0..<operations {
                let operation = randomByte() % 3
                let index = Int(randomByte()) % max(1, edited.count)
                if operation == 0 || edited.isEmpty { edited.insert(randomByte(), at: index) }
                else if operation == 1 { edited.remove(at: index) }
                else { edited[index] = randomByte() }
            }
            let result = try compare(original, edited)
            try validate(result, left: original, right: edited)
            let editCost = result.spans.filter { $0.kind != .equal }.reduce(Int64(0)) { $0 + max($1.leftCount, $1.rightCount) }
            try expect(!result.alignmentIsApproximate && editCost <= operations, "seeded edits must not expand into unrelated changed suffixes")
        }
        let noiseA = Data(repeating: 0, count: 2 * 1024 * 1024)
        let noiseB = Data(repeating: 0xff, count: noiseA.count)
        let coarse = try compare(noiseA, noiseB)
        try validate(coarse, left: noiseA, right: noiseB)
        try expect(coarse.alignmentIsApproximate && coarse.spans.count <= 16_384 && coarse.spans.allSatisfy { $0.kind == .changed },
                   "complex unmatched content uses bounded explicit approximate coverage, never unverified equality")
        try expect(try Data(contentsOf: leftURL) == noiseA && Data(contentsOf: rightURL) == noiseB, "comparison never changes either original")

        let source = try BinaryFileSource(url: leftURL)
        try expect(try source.read(offset: source.size - 4, count: 20) == Data(repeating: 0, count: 4), "range reads truncate only at captured EOF")
        try expect(try source.read(offset: source.size, count: 1).isEmpty, "read at EOF is empty")
        try rejects("negative offsets are rejected") { _ = try source.read(offset: -1, count: 1) }
        try rejects("offsets beyond EOF are rejected") { _ = try source.read(offset: Int64.max, count: 1) }
        try rejects("negative lengths are rejected") { _ = try source.read(offset: 0, count: -1) }
        try rejects("range allocation is capped at one MiB") { _ = try source.read(offset: 0, count: 1024 * 1024 + 1) }
        try rejects("directories are rejected") { _ = try BinaryFileSource(url: root) }
        let fifo = root.appendingPathComponent("pipe")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw Failure(description: "could not make FIFO fixture") }
        try rejects("FIFO is rejected without blocking for a writer") { _ = try BinaryFileSource(url: fifo) }
        let symlink = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: leftURL)
        try rejects("final symbolic links are refused") { _ = try BinaryFileSource(url: symlink) }

        let sparseURL = root.appendingPathComponent("sparse.bin")
        let descriptor = open(sparseURL.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Failure(description: "could not make sparse fixture") }
        defer { close(descriptor) }
        let offset: Int64 = 4 * 1024 * 1024 * 1024 + 19
        let marker = Data([0x31, 0x00, 0xff, 0x7e])
        guard ftruncate(descriptor, off_t(offset + Int64(marker.count))) == 0 else { throw Failure(description: "could not size sparse fixture") }
        let written = marker.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, marker.count, off_t(offset)) }
        guard written == marker.count else { throw Failure(description: "could not write sparse marker") }
        let sparse = try BinaryFileSource(url: sparseURL)
        try expect(sparse.size == offset + 4, "file size preserves all 64 offset bits")
        try expect(try sparse.read(offset: offset - 4, count: 8) == Data([0, 0, 0, 0, 0x31, 0, 0xff, 0x7e]), "pread seeks past four GiB without a whole-file allocation")
        guard ftruncate(descriptor, off_t(BinaryDiffEngine.maximumComparisonBytes + 1)) == 0 else { throw Failure(description: "could not grow sparse fixture") }
        let tooLarge = try BinaryFileSource(url: sparseURL)
        try rejects("comparison rejects inputs over eight GiB before reading content") { _ = try BinaryDiffEngine.compare(left: tooLarge, right: tooLarge) }
        try rejects("a held source notices changed size") { try sparse.verifyUnchanged() }

        let mutationURL = root.appendingPathComponent("mutation.bin")
        try Data([1, 2, 3, 4]).write(to: mutationURL)
        let mutated = try BinaryFileSource(url: mutationURL)
        let writer = try FileHandle(forUpdating: mutationURL)
        try writer.seek(toOffset: 1); try writer.write(contentsOf: Data([9])); try writer.close()
        try rejects("same-size in-place modification invalidates a snapshot") { try mutated.verifyUnchanged() }
        let replaced = try BinaryFileSource(url: mutationURL)
        try Data([1, 9, 3, 4]).write(to: mutationURL, options: .atomic)
        try rejects("replacement with identical bytes is detected by path identity") { _ = try replaced.read(offset: 0, count: 4) }
        let truncated = try BinaryFileSource(url: mutationURL)
        let truncator = try FileHandle(forWritingTo: mutationURL); try truncator.truncate(atOffset: 1); try truncator.close()
        try rejects("truncated files are rejected before publishing partial bytes") { _ = try truncated.read(offset: 0, count: 4) }

        let cancelled = await Task.detached { () -> Bool in
            do {
                _ = try BinaryDiffEngine.compare(left: source, right: source, progress: { value in
                    if value > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                })
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(cancelled, "cancellation during streamed comparison returns no partial result")
        let readCancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try source.read(offset: 0, count: 1); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        try expect(readCancelled, "cancelled range reads do not touch input bytes")
        let rangesMatch = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<16 { group.addTask { try source.read(offset: Int64(index * 4096), count: 256) == Data(repeating: 0, count: 256) } }
            var valid = true
            for try await match in group { valid = valid && match }
            return valid
        }
        try expect(rangesMatch, "concurrent pread calls retain independent offsets")
        let progress = ProgressRecorder()
        _ = try BinaryDiffEngine.compare(left: source, right: source, progress: { progress.record($0) })
        try expect(progress.valid, "progress is monotone and bounded from zero through completion")
        let finalMutationURL = root.appendingPathComponent("final-mutation.bin")
        try Data([1, 2, 3, 4]).write(to: finalMutationURL)
        let finalMutation = try BinaryFileSource(url: finalMutationURL)
        try rejects("mutation after the last compared block invalidates publication") {
            _ = try BinaryDiffEngine.compare(left: finalMutation, right: finalMutation, progress: { value in
                if value == 1 { try? Data([5, 6, 7, 8]).write(to: finalMutationURL, options: .atomic) }
            })
        }

        let leadingInsertion = try compare(Data([0x41, 0x42]), Data([0, 0x41, 0x42]))
        let layout = BinaryRowLayout(result: leadingInsertion, bytesPerRow: 8)
        let cells = layout.rows(start: 0, count: 1)[0].cells
        try expect(cells[0].leftOffset == nil && cells[0].rightOffset == 0 && cells[0].kind == .added,
                   "leading insertion is a display gap, not a fabricated left zero byte")
        try expect(cells[1].leftOffset == 0 && cells[1].rightOffset == 1 && cells[1].kind == .equal,
                   "display alignment retains distinct source offsets after insertion")
        let unequal = BinaryComparisonResult(spans: [BinarySpan(kind: .changed, leftOffset: 0, rightOffset: 0, leftCount: 2, rightCount: 4)],
                                            leftSize: 2, rightSize: 4, alignmentIsApproximate: true)
        let unequalCells = BinaryRowLayout(result: unequal, bytesPerRow: 16).rows(start: 0, count: 1)[0].cells
        try expect(unequalCells[2].leftOffset == nil && unequalCells[2].rightOffset == 2 && unequalCells[2].kind == .added,
                   "unequal changed extents show the unmatched tail as a gap")
        let bigOffset: Int64 = 4 * 1024 * 1024 * 1024
        let hugeResult = BinaryComparisonResult(spans: [
            BinarySpan(kind: .equal, leftOffset: 0, rightOffset: 0, leftCount: bigOffset, rightCount: bigOffset),
            BinarySpan(kind: .added, leftOffset: bigOffset, rightOffset: bigOffset, leftCount: 0, rightCount: 1),
            BinarySpan(kind: .equal, leftOffset: bigOffset, rightOffset: bigOffset + 1, leftCount: 16_384, rightCount: 16_384)],
            leftSize: bigOffset + 16_384, rightSize: bigOffset + 16_385, alignmentIsApproximate: false)
        let hugeLayout = BinaryRowLayout(result: hugeResult, bytesPerRow: 16)
        try expect(hugeLayout.row(forSpanIndex: 1) == bigOffset / 16 && hugeLayout.row(containingOffset: bigOffset + 16, side: .right) == bigOffset / 16 + 1,
                   "span and raw address jumps retain offsets beyond four GiB")
        let hugeRows = hugeLayout.rows(start: bigOffset / 16, count: Int.max)
        try expect(hugeRows.count == 512 && hugeRows[0].cells[1].leftOffset == bigOffset && hugeRows[0].cells[1].rightOffset == bigOffset + 1,
                   "large-file row pages are bounded and preserve post-gap source mapping")
        try expect(hugeLayout.rows(start: Int64.max, count: Int.max).isEmpty && hugeLayout.row(containingOffset: -1, side: .left) == nil,
                   "invalid row and source addresses do not allocate or overflow")
        let slicedBytes = Data([9, 8, 0x41, 0xff]).dropFirst(2)
        let page = BinaryPage(startRow: 0, rows: layout.rows(start: 0, count: 1), leftOffset: 0, leftBytes: slicedBytes,
                              rightOffset: 0, rightBytes: Data([0, 0x41, 0x42]))
        try expect(page.byte(at: 0, side: .left) == 0x41 && page.bytes(in: 0..<2, side: .left) == Data([0x41, 0xff]),
                   "viewport byte lookup honors Data slice indices")



    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var valid: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.first == 0 && values.last == 1 && values.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
            zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

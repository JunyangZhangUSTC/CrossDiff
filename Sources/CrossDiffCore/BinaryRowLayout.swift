import Foundation

public enum BinaryDataSide: String, Sendable { case left, right }

/// A cell in the aligned byte stream. A missing offset is an alignment gap,
/// never a zero byte. Source offsets remain independent of display positions.
public struct BinaryLayoutCell: Sendable, Equatable {
    public let alignedOffset: Int64
    public let leftOffset: Int64?
    public let rightOffset: Int64?
    public let kind: BinaryChangeKind
    public let spanIndex: Int

    public init(alignedOffset: Int64, leftOffset: Int64?, rightOffset: Int64?, kind: BinaryChangeKind, spanIndex: Int) {
        self.alignedOffset = alignedOffset; self.leftOffset = leftOffset; self.rightOffset = rightOffset
        self.kind = kind; self.spanIndex = spanIndex
    }
    public func offset(on side: BinaryDataSide) -> Int64? { side == .left ? leftOffset : rightOffset }
}

public struct BinaryLayoutRow: Sendable, Equatable {
    public let index: Int64
    public let cells: [BinaryLayoutCell]
    public init(index: Int64, cells: [BinaryLayoutCell]) { self.index = index; self.cells = cells }
}

/// Only the bounded loaded page holds bytes. It does not own file handles or
/// allocate data for rows outside the requested viewport and its small buffer.
public struct BinaryPage: Sendable {
    public let startRow: Int64
    public let rows: [BinaryLayoutRow]
    public let leftOffset: Int64
    public let leftBytes: Data
    public let rightOffset: Int64
    public let rightBytes: Data

    public init(startRow: Int64, rows: [BinaryLayoutRow], leftOffset: Int64, leftBytes: Data,
                rightOffset: Int64, rightBytes: Data) {
        self.startRow = startRow; self.rows = rows
        self.leftOffset = leftOffset; self.leftBytes = leftBytes
        self.rightOffset = rightOffset; self.rightBytes = rightBytes
    }
    public func row(at index: Int64) -> BinaryLayoutRow? {
        guard index >= startRow else { return nil }
        let local = index - startRow
        guard local < Int64(rows.count) else { return nil }
        return rows[Int(local)]
    }
    public func byte(at offset: Int64, side: BinaryDataSide) -> UInt8? {
        let origin = side == .left ? leftOffset : rightOffset
        let bytes = side == .left ? leftBytes : rightBytes
        guard offset >= origin else { return nil }
        let local = offset - origin
        guard local < Int64(bytes.count) else { return nil }
        return bytes[bytes.startIndex + Int(local)]
    }
    public func bytes(in range: Range<Int64>, side: BinaryDataSide) -> Data? {
        let origin = side == .left ? leftOffset : rightOffset
        let bytes = side == .left ? leftBytes : rightBytes
        guard range.lowerBound >= origin, range.upperBound >= range.lowerBound,
              range.upperBound - origin <= Int64(bytes.count) else { return nil }
        return bytes.subdata(in: (bytes.startIndex + Int(range.lowerBound - origin))..<(bytes.startIndex + Int(range.upperBound - origin)))
    }
}

/// An O(span count) index into an arbitrarily large aligned byte stream.
/// Constructing a layout does not construct rows; each page is capped at 512.
public struct BinaryRowLayout: Sendable {
    public static let maximumPageRows = 512
    public let bytesPerRow: Int
    public let alignedCount: Int64
    public let totalRows: Int64
    private let spans: [BinarySpan]
    private let starts: [Int64]

    public init(result: BinaryComparisonResult, bytesPerRow: Int) {
        self.bytesPerRow = bytesPerRow == 8 ? 8 : 16
        spans = result.spans
        var offsets: [Int64] = []
        offsets.reserveCapacity(result.spans.count)
        var count: Int64 = 0
        for span in result.spans {
            offsets.append(count)
            count += max(span.leftCount, span.rightCount)
        }
        starts = offsets; alignedCount = count
        totalRows = count / Int64(self.bytesPerRow) + (count % Int64(self.bytesPerRow) == 0 ? 0 : 1)
    }

    public func row(forSpanIndex index: Int) -> Int64? {
        guard starts.indices.contains(index) else { return nil }
        return starts[index] / Int64(bytesPerRow)
    }

    public func row(containingOffset offset: Int64, side: BinaryDataSide) -> Int64? {
        guard offset >= 0 else { return nil }
        var lower = 0, upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let span = spans[middle]
            let end = side == .left ? span.leftOffset + span.leftCount : span.rightOffset + span.rightCount
            if end <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard spans.indices.contains(lower) else { return nil }
        let span = spans[lower]
        let start = side == .left ? span.leftOffset : span.rightOffset
        guard offset >= start else { return nil }
        return (starts[lower] + offset - start) / Int64(bytesPerRow)
    }

    public func rows(start: Int64, count: Int) -> [BinaryLayoutRow] {
        guard start >= 0, start < totalRows, count > 0 else { return [] }
        let rowCount = Int(min(Int64(min(count, Self.maximumPageRows)), totalRows - start))
        var position = start * Int64(bytesPerRow)
        var lower = 0, upper = spans.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let end = starts[middle] + max(spans[middle].leftCount, spans[middle].rightCount)
            if end <= position { lower = middle + 1 } else { upper = middle }
        }
        var spanIndex = lower
        var rows: [BinaryLayoutRow] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            var cells: [BinaryLayoutCell] = []
            cells.reserveCapacity(bytesPerRow)
            for _ in 0..<bytesPerRow where position < alignedCount {
                while spanIndex < spans.count,
                      position >= starts[spanIndex] + max(spans[spanIndex].leftCount, spans[spanIndex].rightCount) {
                    spanIndex += 1
                }
                guard spanIndex < spans.count else { break }
                let span = spans[spanIndex], local = position - starts[spanIndex]
                let left = local < span.leftCount ? span.leftOffset + local : nil
                let right = local < span.rightCount ? span.rightOffset + local : nil
                let kind: BinaryChangeKind = left == nil ? .added : (right == nil ? .removed : span.kind)
                cells.append(BinaryLayoutCell(alignedOffset: position, leftOffset: left, rightOffset: right,
                                              kind: kind, spanIndex: spanIndex))
                position += 1
            }
            rows.append(BinaryLayoutRow(index: start + Int64(rowIndex), cells: cells))
        }
        return rows
    }
}

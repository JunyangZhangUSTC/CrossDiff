import Foundation
import CryptoKit

/// Only these readers are registered. No automatic format/program-filter bidding.
enum ArchiveNativeFormat: String {
    case sevenZip = "7zip", rar4 = "rar", rar5
    static func identify(_ bytes: Data) -> Self? {
        if bytes.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return .sevenZip }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]) { return .rar4 }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]) { return .rar5 }
        return nil
    }
}

struct ArchiveReaderReply: Codable {
    let entries: [ArchiveEntry]?
    let totalExpandedBytes: Int64?
    let error: ArchiveError?
}

/// Preflight validates container layout, coder limits and declared entries before
/// the system decoder runs. Every regular entry is drained, CRC checked when
/// present, and SHA-256 hashed. Nothing is extracted or followed on disk.
enum ArchiveNativeReader {
    private struct GroupCheck {
        let record: Archive7z.ChecksumGroup
        var nextIndex = 0
        var size: Int64 = 0
        var crc = ArchiveContentCRC()
    }
    struct Entry {
        let path: String
        let kind: ArchiveEntryKind
        let size: Int64
        let crc32: UInt32?
    }
    static func read(_ input: ArchiveInput) throws -> ArchiveSnapshot {
        guard input.size <= ArchiveCatalog.maximumSourceBytes,
              let format = ArchiveNativeFormat.identify(try input.read(offset: 0, count: 8)) else { throw ArchiveError.unsupported }
        let records: [Entry]
        var groups: [GroupCheck] = []
        if format == .sevenZip {
            let metadata = try Archive7z.validate(input)
            groups = metadata.checksumGroups.map { GroupCheck(record: $0) }
            records = metadata.entries.map {
                Entry(path: $0.rawPath, kind: $0.kind, size: $0.size, crc32: $0.crc32)
            }
        } else {
            records = try ArchiveRAR.validate(input).entries.map {
                Entry(path: $0.path, kind: $0.kind, size: $0.size, crc32: $0.crc32)
            }
        }
        let builder = ArchiveBuilder(); builder.stamps.append(input.stamp)
        let stream = try ArchiveStream(input: input, format: format.rawValue)
        // System readers can reorder empty files/directories. Match exact paths
        // against the checked table, never infer completeness from an EOF alone.
        var expected: [String: Entry] = [:]
        var groupForPath: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for path in group.record.paths {
                guard groupForPath.updateValue(index, forKey: path) == nil else { throw ArchiveError.damaged }
            }
        }
        for record in records {
            let path = try ArchiveBuilder.normalize(record.path, directory: record.kind == .directory) ?? "."
            guard expected.updateValue(record, forKey: path) == nil else { throw ArchiveError.duplicatePath(path) }
        }
        while let header = try stream.next() {
            let entry = try stream.description(header)
            let path = try ArchiveBuilder.normalize(entry.path, directory: entry.kind == .directory) ?? "."
            guard let record = expected.removeValue(forKey: path), record.kind == entry.kind else { throw ArchiveError.damaged }
            let groupIndex = groupForPath[path]
            if let index = groupIndex {
                guard groups[index].nextIndex < groups[index].record.paths.count,
                      groups[index].record.paths[groups[index].nextIndex] == path else { throw ArchiveError.damaged }
            }
            if entry.kind != .symbolicLink {
                guard entry.size == record.size else { throw ArchiveError.damaged }
            }
            var amount: Int64 = 0, hash = SHA256(), crc = ArchiveContentCRC()
            func consume(_ bytes: Data) throws {
                amount += Int64(bytes.count)
                guard amount <= record.size else { throw ArchiveError.damaged }
                try builder.account(Int64(bytes.count), fileBytes: amount)
                hash.update(data: bytes); crc.update(bytes)
                if let index = groupIndex {
                    groups[index].size += Int64(bytes.count)
                    groups[index].crc.update(bytes)
                }
            }
            if entry.kind == .symbolicLink {
                try consume(stream.symbolicLinkBytes(header))
                guard try stream.read().isEmpty else { throw ArchiveError.damaged }
            } else {
                while true {
                    let bytes = try stream.read()
                    if bytes.isEmpty { break }
                    try consume(bytes)
                }
            }
            guard amount == record.size, record.crc32 == nil || crc.value == record.crc32 else { throw ArchiveError.damaged }
            if let index = groupIndex { groups[index].nextIndex += 1 }
            let issue: ArchiveEntryIssue?
            switch entry.kind {
            case .file, .directory: issue = nil
            case .symbolicLink: issue = .symbolicLink
            case .hardLink: issue = .hardLink
            case .other: issue = .specialFile
            }
            try builder.add(rawPath: entry.path, kind: entry.kind, size: amount,
                            digest: entry.kind == .file ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil, issue: issue)
        }
        guard expected.isEmpty else { throw ArchiveError.damaged }
        for group in groups {
            guard group.nextIndex == group.record.paths.count, group.size == group.record.size,
                  group.crc.value == group.record.crc32 else { throw ArchiveError.damaged }
        }
        // 7z seeks; source-filter byte counters are not physical EOF indicators.
        // The strict preflight already checks the exact physical archive extent.
        try stream.finish()
        return try builder.finish(url: input.stamp.url, kind: .archive)
    }
}

private struct ArchiveContentCRC {
    private var state: UInt32 = 0xffffffff
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }
    mutating func update(_ bytes: Data) {
        for byte in bytes { state = Self.table[Int((state ^ UInt32(byte)) & 0xff)] ^ (state >> 8) }
    }
    var value: UInt32 { state ^ 0xffffffff }
}

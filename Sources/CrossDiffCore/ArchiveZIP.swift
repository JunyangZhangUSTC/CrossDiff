import Foundation
import CryptoKit
import Darwin

/// A deliberately strict ZIP32 subset. Inspect raw names before libarchive can
/// expose them as NUL-terminated strings, and reject ambiguous hidden records.
enum ArchiveZIPReader {
    struct Record {
        let rawName: Data
        let path: String
        let kind: ArchiveEntryKind
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressed: Int64
        let size: Int64
        let localOffset: Int64
    }
    static func read(_ input: ArchiveInput, builder: ArchiveBuilder) throws {
        let records = try directory(input)
        if records.isEmpty { return }
        let stream = try ArchiveStream(input: input, zip: true)
        var seen = Set<String>()
        while let entry = try stream.next() {
            let description = try stream.description(entry)
            let path = try ArchiveBuilder.normalize(description.path, directory: description.kind == .directory) ?? ""
            guard let record = records[path], seen.insert(path).inserted,
                  description.kind == record.kind else { throw ArchiveError.damaged }
            if description.kind == .file || description.kind == .directory {
                if let declared = description.size, declared != record.size { throw ArchiveError.damaged }
            }
            var hash = SHA256(), crc = ZIPCRC(), amount: Int64 = 0
            while true {
                let bytes = try stream.read()
                if bytes.isEmpty { break }
                amount += Int64(bytes.count)
                guard amount <= record.size else { throw ArchiveError.damaged }
                try builder.account(Int64(bytes.count), fileBytes: amount)
                hash.update(data: bytes); crc.update(bytes)
            }
            // libarchive materializes ZIP symlink targets while reading headers,
            // rather than returning their bytes from archive_read_data.
            if record.kind == .symbolicLink && amount == 0 {
                let bytes = try stream.symbolicLinkBytes(entry)
                amount = Int64(bytes.count)
                try builder.account(amount, fileBytes: amount)
                crc.update(bytes)
            }
            guard amount == record.size, crc.value == record.crc else { throw ArchiveError.damaged }
            let digest = record.kind == .file ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil
            let issue: ArchiveEntryIssue? = record.kind == .symbolicLink ? .symbolicLink : record.kind == .other ? .specialFile : nil
            try builder.add(rawPath: description.path, kind: record.kind, size: record.kind == .file ? amount : record.kind == .directory ? 0 : nil, digest: digest, issue: issue)
        }
        guard seen.count == records.count else { throw ArchiveError.damaged }
        try stream.finish()
    }
    static func directory(_ input: ArchiveInput) throws -> [String: Record] {
        guard input.size >= 22 else { throw ArchiveError.damaged }
        let tailStart = max(0, input.size - 65_557)
        let tail = try input.read(offset: tailStart, count: Int(input.size - tailStart))
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50, index + 22 + Int(tail.u16(index + 20)) == tail.count { end = index; break }
        }
        guard let end else { throw ArchiveError.damaged }
        let endOffset = tailStart + Int64(end)
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10) else { throw ArchiveError.unsupported }
        let count = Int(tail.u16(end + 10)), directorySize = Int64(tail.u32(end + 12)), directoryOffset = Int64(tail.u32(end + 16))
        guard count != 65_535, directorySize != Int64(UInt32.max), directoryOffset != Int64(UInt32.max) else { throw ArchiveError.unsupported }
        guard count <= ArchiveCatalog.maximumEntries else { throw ArchiveError.limit }
        guard directoryOffset + directorySize == endOffset else { throw ArchiveError.damaged }
        var position = directoryOffset, records: [String: Record] = [:], total: Int64 = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            let header = try input.read(offset: position, count: 46)
            guard header.count == 46, header.u32(0) == 0x02014b50 else { throw ArchiveError.damaged }
            let flags = header.u16(8), method = header.u16(10)
            guard flags & 0x2041 == 0 else { throw ArchiveError.encrypted }
            guard method == 0 || method == 8, header.u16(34) == 0 else { throw ArchiveError.unsupported }
            let compressed = Int64(header.u32(20)), size = Int64(header.u32(24)), localOffset = Int64(header.u32(42))
            guard compressed != Int64(UInt32.max), size != Int64(UInt32.max), localOffset != Int64(UInt32.max) else { throw ArchiveError.unsupported }
            let nameSize = Int(header.u16(28)), extraSize = Int(header.u16(30)), commentSize = Int(header.u16(32))
            guard nameSize > 0, nameSize <= ArchiveCatalog.maximumPathBytes else { throw ArchiveError.invalidPath }
            let remainder = try input.read(offset: position + 46, count: nameSize + extraSize + commentSize)
            guard remainder.count == nameSize + extraSize + commentSize else { throw ArchiveError.damaged }
            let rawName = Data(remainder.prefix(nameSize))
            guard !rawName.contains(0), let name = String(data: rawName, encoding: .utf8) else { throw ArchiveError.invalidPath }
            try checkExtras(Data(remainder.dropFirst(nameSize).prefix(extraSize)))
            let unixType = mode_t(header.u32(38) >> 16) & mode_t(S_IFMT)
            if unixType == mode_t(S_IFREG) && name.hasSuffix("/") { throw ArchiveError.invalidPath }
            let kind: ArchiveEntryKind
            if unixType == mode_t(S_IFLNK) { kind = .symbolicLink }
            else if unixType == mode_t(S_IFDIR) || name.hasSuffix("/") { kind = .directory }
            else if unixType == 0 || unixType == mode_t(S_IFREG) { kind = .file }
            else { kind = .other }
            let path = try ArchiveBuilder.normalize(name, directory: kind == .directory) ?? ""
            guard records[path] == nil else { throw ArchiveError.duplicatePath(path) }
            guard size <= ArchiveCatalog.maximumFileBytes, total <= ArchiveCatalog.maximumExpandedBytes - size else { throw ArchiveError.limit }
            if kind == .directory && size != 0 { throw ArchiveError.damaged }
            // Link targets are materialized by the system reader before it yields
            // a header; keep that allocation small as well as the streaming data.
            if kind != .file && size > 4096 { throw ArchiveError.limit }
            total += size
            records[path] = Record(rawName: rawName, path: path, kind: kind, flags: flags, method: method, crc: header.u32(16), compressed: compressed, size: size, localOffset: localOffset)
            position += Int64(46 + remainder.count)
            guard position <= endOffset else { throw ArchiveError.damaged }
        }
        guard position == endOffset else { throw ArchiveError.damaged }
        var localEnd: Int64 = 0
        for record in records.values.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard record.localOffset == localEnd else { throw ArchiveError.unsupported }
            let header = try input.read(offset: localEnd, count: 30)
            guard header.count == 30, header.u32(0) == 0x04034b50,
                  header.u16(6) == record.flags, header.u16(8) == record.method else { throw ArchiveError.damaged }
            let nameSize = Int(header.u16(26)), extraSize = Int(header.u16(28))
            let remainder = try input.read(offset: localEnd + 30, count: nameSize + extraSize)
            guard remainder.count == nameSize + extraSize, Data(remainder.prefix(nameSize)) == record.rawName else { throw ArchiveError.damaged }
            try checkExtras(Data(remainder.dropFirst(nameSize)))
            localEnd += Int64(30 + remainder.count) + record.compressed
            guard localEnd <= directoryOffset else { throw ArchiveError.damaged }
            if record.flags & 8 == 0 {
                guard header.u32(14) == record.crc, Int64(header.u32(18)) == record.compressed, Int64(header.u32(22)) == record.size else { throw ArchiveError.damaged }
            } else {
                var descriptor = try input.read(offset: localEnd, count: 16)
                guard descriptor.count >= 12 else { throw ArchiveError.damaged }
                if descriptor.u32(0) == 0x08074b50 {
                    guard descriptor.count == 16 else { throw ArchiveError.damaged }
                    descriptor = Data(descriptor.dropFirst(4)); localEnd += 4
                }
                guard descriptor.u32(0) == record.crc, Int64(descriptor.u32(4)) == record.compressed, Int64(descriptor.u32(8)) == record.size else { throw ArchiveError.damaged }
                localEnd += 12
            }
        }
        guard localEnd == directoryOffset else { throw ArchiveError.damaged }
        return records
    }
    private static func checkExtras(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { throw ArchiveError.damaged }
            let kind = bytes.u16(offset), size = Int(bytes.u16(offset + 2))
            guard size <= bytes.count - offset - 4 else { throw ArchiveError.damaged }
            // Unicode path overrides would make the raw and decoded identities
            // differ. This preview accepts the original, valid UTF-8 name only.
            guard kind != 1, kind != 0x7075 else { throw ArchiveError.unsupported }
            offset += 4 + size
        }
    }
}
private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
private struct ZIPCRC {
    private static let table: [UInt32] = (0..<256).map { value in
        var value = UInt32(value)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    private var state: UInt32 = 0xffffffff
    var value: UInt32 { state ^ 0xffffffff }
    mutating func update(_ data: Data) {
        for byte in data { state = (state >> 8) ^ Self.table[Int((state ^ UInt32(byte)) & 255)] }
    }
}

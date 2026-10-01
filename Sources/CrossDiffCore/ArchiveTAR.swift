import Foundation
import CryptoKit

/// TAR metadata is parsed before conversion to C strings, so embedded NUL,
/// invalid UTF-8 and PAX path overrides cannot silently change an entry's name.
/// Only ordinary V7/USTAR/PAX/GNU long-name entries are supported; sparse and
/// multi-volume extensions fail rather than being hashed as complete files.
enum ArchiveTARReader {
    static func read(_ input: ArchiveInput, builder: ArchiveBuilder) throws {
        let stream = try ArchiveStream(input: input, zip: false)
        guard try stream.next() != nil else { throw ArchiveError.damaged }
        let reader = TARBytes(stream)
        var pending: [String: String] = [:], longName: String?
        var records = 0, headers = 0
        while true {
            try Task.checkCancellation()
            let header = try reader.exact(512)
            if header.allSatisfy({ $0 == 0 }) {
                guard try reader.exact(512).allSatisfy({ $0 == 0 }), pending.isEmpty, longName == nil else { throw ArchiveError.damaged }
                // Drain the entire compression stream, including its trailer: a
                // TAR end marker alone does not establish a valid gzip/xz CRC.
                try reader.finishZeroPadding()
                guard try stream.next() == nil else { throw ArchiveError.damaged }
                try stream.verifySourceConsumed()
                try stream.finish()
                return
            }
            headers += 1
            guard headers <= 30_000 else { throw ArchiveError.limit }
            let expectedChecksum = try number(header.subdata(in: 148..<156))
            let actualChecksum = header.enumerated().reduce(Int64(0)) { $0 + ((148..<156).contains($1.offset) ? 32 : Int64($1.element)) }
            guard expectedChecksum == actualChecksum else { throw ArchiveError.damaged }
            let type = header[156]
            var name = try field(header.subdata(in: 0..<100))
            if header.subdata(in: 257..<263) == Data([117, 115, 116, 97, 114, 0]) {
                let prefix = try field(header.subdata(in: 345..<500))
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let declared = try number(header.subdata(in: 124..<136))
            if [UInt8(120), 103, 76, 75].contains(type) { // PAX x/g, GNU L/K
                guard declared <= 64 * 1024 else { throw ArchiveError.limit }
                let data = try reader.exact(Int(declared)); try reader.padding(after: declared)
                if type == 120 || type == 103 {
                    let fields = try pax(data)
                    if type == 103 {
                        guard fields["path"] == nil, fields["linkpath"] == nil, fields["size"] == nil else { throw ArchiveError.unsupported }
                    } else { pending.merge(fields) { _, new in new } }
                } else {
                    let value = try field(data)
                    guard value.utf8.count <= ArchiveCatalog.maximumPathBytes else { throw ArchiveError.limit }
                    if type == 76 { longName = value }
                }
                continue
            }
            guard ![UInt8(83), 77, 86, 68].contains(type) else { throw ArchiveError.unsupported } // sparse/multivolume/dumpdir
            records += 1
            guard records <= ArchiveCatalog.maximumEntries else { throw ArchiveError.limit }
            name = pending["path"] ?? longName ?? name
            var size = declared
            if let value = pending["size"] {
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int64(value), parsed >= 0 else { throw ArchiveError.damaged }
                size = parsed
            }
            pending.removeAll(keepingCapacity: true); longName = nil
            let kind: ArchiveEntryKind
            switch type {
            case 0, 48, 55: kind = .file
            case 53: kind = .directory
            case 50: kind = .symbolicLink
            case 49: kind = .hardLink
            default: kind = .other
            }
            _ = try ArchiveBuilder.normalize(name, directory: kind == .directory)
            guard size <= ArchiveCatalog.maximumFileBytes,
                  size <= ArchiveCatalog.maximumExpandedBytes - builder.totalBytes else { throw ArchiveError.limit }
            if kind == .directory, size != 0 { throw ArchiveError.damaged }
            var remaining = size, hash = SHA256()
            while remaining > 0 {
                let data = try reader.exact(Int(min(64 * 1024, remaining)))
                try builder.account(Int64(data.count), fileBytes: size)
                if kind == .file { hash.update(data: data) }
                remaining -= Int64(data.count)
            }
            try reader.padding(after: size)
            let issue: ArchiveEntryIssue? = kind == .symbolicLink ? .symbolicLink : (kind == .hardLink ? .hardLink : (kind == .other ? .specialFile : nil))
            try builder.add(rawPath: name, kind: kind, size: kind == .directory ? 0 : (kind == .file ? size : nil),
                            digest: kind == .file ? hash.finalize().map { String(format: "%02x", $0) }.joined() : nil, issue: issue)
        }
    }
    private static func field(_ bytes: Data) throws -> String {
        let content: Data
        if let index = bytes.firstIndex(of: 0) {
            guard bytes[index...].allSatisfy({ $0 == 0 }) else { throw ArchiveError.invalidPath }
            content = Data(bytes[..<index])
        } else { content = bytes }
        guard let value = String(data: content, encoding: .utf8) else { throw ArchiveError.invalidPath }
        return value
    }
    private static func number(_ bytes: Data) throws -> Int64 {
        var value: Int64 = 0
        if let first = bytes.first, first & 0x80 != 0 {
            guard first & 0x40 == 0 else { throw ArchiveError.unsupported }
            for (index, byte) in bytes.enumerated() {
                let digit = Int64(index == 0 ? byte & 0x7f : byte)
                guard value <= (Int64.max - digit) / 256 else { throw ArchiveError.limit }
                value = value * 256 + digit
            }
            return value
        }
        guard let string = String(data: bytes, encoding: .ascii) else { throw ArchiveError.damaged }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        for byte in trimmed.utf8 {
            guard (48...55).contains(byte), value <= (Int64.max - Int64(byte - 48)) / 8 else { throw ArchiveError.damaged }
            value = value * 8 + Int64(byte - 48)
        }
        return value
    }
    private static func pax(_ data: Data) throws -> [String: String] {
        var offset = 0, result: [String: String] = [:]
        while offset < data.count {
            try Task.checkCancellation()
            guard let space = data[offset...].firstIndex(of: 32), space - offset <= 10,
                  let sizeString = String(data: data[offset..<space], encoding: .ascii),
                  sizeString.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(sizeString),
                  length > space - offset + 2, length <= data.count - offset, data[offset + length - 1] == 10 else { throw ArchiveError.damaged }
            let body = data[(space + 1)..<(offset + length - 1)]
            guard let separator = body.firstIndex(of: 61), let key = String(data: body[..<separator], encoding: .utf8) else { throw ArchiveError.damaged }
            if key.hasPrefix("GNU.sparse") || key == "SCHILY.realsize" || key == "SCHILY.filetype" { throw ArchiveError.unsupported }
            if ["path", "linkpath", "size"].contains(key) {
                let raw = body[(separator + 1)...]
                guard !raw.contains(0), raw.count <= ArchiveCatalog.maximumPathBytes,
                      let value = String(data: raw, encoding: .utf8) else { throw ArchiveError.invalidPath }
                result[key] = value
            }
            offset += length
        }
        return result
    }
}

private final class TARBytes {
    let stream: ArchiveStream
    private var buffer = Data(), cursor = 0
    private var consumed: Int64 = 0
    init(_ stream: ArchiveStream) { self.stream = stream }
    private func refill() throws -> Bool {
        if cursor < buffer.count { return true }
        buffer = try stream.read(); cursor = 0
        consumed += Int64(buffer.count)
        guard consumed <= ArchiveCatalog.maximumExpandedBytes + 32 * 1024 * 1024 else { throw ArchiveError.limit }
        return !buffer.isEmpty
    }
    func exact(_ count: Int) throws -> Data {
        guard count >= 0, count <= 64 * 1024 else { throw ArchiveError.limit }
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            guard try refill() else { throw ArchiveError.damaged }
            let length = min(count - result.count, buffer.count - cursor)
            result.append(buffer[cursor..<(cursor + length)]); cursor += length
        }
        return result
    }
    func padding(after size: Int64) throws {
        let count = Int((512 - size % 512) % 512)
        guard try exact(count).allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
    }
    func finishZeroPadding() throws {
        while try refill() {
            try Task.checkCancellation()
            guard buffer[cursor...].allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
            cursor = buffer.count
        }
    }
}

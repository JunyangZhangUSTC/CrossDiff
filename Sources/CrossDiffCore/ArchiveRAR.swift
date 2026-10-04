import Foundation

/// Structural admission checks, independent of libarchive's permissive skipping.
/// RAR5 layout: https://www.rarlab.com/technote.htm. RAR4 field definitions were
/// checked against libarchive 3.8.9; no decompressor is implemented here.
enum ArchiveRAR {
    struct Entry {
        let path: String
        let kind: ArchiveEntryKind
        let size: Int64
        let crc32: UInt32?
        let dataOffset: Int64
        let packedSize: Int64
    }
    struct Metadata {
        let format: ArchiveNativeFormat
        let entries: [Entry]
    }

    static func validate(_ input: ArchiveInput) throws -> Metadata {
        guard input.size <= ArchiveCatalog.maximumSourceBytes else { throw ArchiveError.limit }
        let signature = try input.read(offset: 0, count: 8)
        if signature.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]) {
            return try rar4(input)
        }
        if signature == Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]) {
            return try rar5(input)
        }
        // In particular, do not search for an embedded signature in an SFX.
        throw ArchiveError.unsupported
    }

    private static func rar4(_ input: ArchiveInput) throws -> Metadata {
        var offset: Int64 = 7, mainSeen = false, entries: [Entry] = []
        let budget = ArchiveBuilder()
        var headerBytes = 0
        while offset < input.size {
            try Task.checkCancellation()
            let prefix = try exact(input, offset, 7)
            let type = prefix[2], flags = little16(prefix, 3), size = Int(little16(prefix, 5))
            guard size >= 7 else { throw ArchiveError.damaged }
            let header = try exact(input, offset, size)
            try accountHeader(size, total: &headerBytes)
            guard checksum(header.dropFirst(2)) & 0xffff == UInt32(little16(header, 0)) else { throw ArchiveError.damaged }
            let dataOffset = offset + Int64(size)
            switch type {
            case 0x73:
                guard !mainSeen, offset == 7 else { throw ArchiveError.damaged }
                if flags & 0x0080 != 0 { throw ArchiveError.encrypted }
                if flags & 0x0101 != 0 { throw ArchiveError.multiVolume }
                // Lock and the naming convention bit do not affect decoding.
                guard flags & ~UInt16(0x0014) == 0 else { throw ArchiveError.unsupported }
                guard size == 13, header[7..<13].allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
                mainSeen = true
                offset = dataOffset
            case 0x74:
                guard mainSeen, size >= 32 else { throw ArchiveError.damaged }
                if flags & 0x0003 != 0 { throw ArchiveError.multiVolume }
                if flags & 0x0404 != 0 { throw ArchiveError.encrypted }
                // Solid, comments, versioned files, extended flags and unknown
                // bits cannot silently become ordinary verified files.
                guard flags & ~UInt16(0xd3e0) == 0 else { throw ArchiveError.unsupported }
                guard flags & 0x8000 != 0 else { throw ArchiveError.damaged }
                var cursor = Cursor(header, position: 7)
                var packed = UInt64(try cursor.u32())
                var unpacked = UInt64(try cursor.u32())
                let host = try cursor.byte(), crc = try cursor.u32()
                _ = try cursor.u32() // DOS timestamp.
                let version = try cursor.byte(), method = try cursor.byte()
                let nameSize = Int(try cursor.u16()), attributes = try cursor.u32()
                guard (0x30...0x35).contains(method), (15...29).contains(version),
                      method == 0x30 || version == 29 else { throw ArchiveError.unsupported }
                if flags & 0x0100 != 0 {
                    packed |= UInt64(try cursor.u32()) << 32
                    unpacked |= UInt64(try cursor.u32()) << 32
                }
                guard nameSize > 0, nameSize <= ArchiveCatalog.maximumPathBytes else { throw ArchiveError.limit }
                let name = try rar4Name(cursor.take(nameSize), unicode: flags & 0x0200 != 0)
                if flags & 0x1000 != 0 {
                    let timeFlags = try cursor.u16()
                    for index in 0..<4 {
                        let part = Int((timeFlags >> (12 - index * 4)) & 15)
                        if part & 8 != 0 {
                            if index != 0 { _ = try cursor.take(4) }
                            _ = try cursor.take(part & 3)
                        } else if part != 0 { throw ArchiveError.damaged }
                    }
                }
                guard cursor.isAtEnd else { throw ArchiveError.unsupported }
                let directory = flags & 0x00e0 == 0x00e0
                let kind = try rar4Kind(host: host, attributes: attributes, directory: directory)
                guard packed <= UInt64(input.size - dataOffset) else { throw ArchiveError.damaged }
                guard unpacked <= UInt64(ArchiveCatalog.maximumFileBytes) else { throw ArchiveError.limit }
                if kind == .directory {
                    guard packed == 0, unpacked == 0 else { throw ArchiveError.damaged }
                } else if method == 0x30 {
                    guard packed == unpacked else { throw ArchiveError.damaged }
                }
                if kind == .symbolicLink {
                    // The system RAR4 reader exposes link bytes inside next_header
                    // and does not decompress them; admit only stored UTF-8 links.
                    guard method == 0x30 else { throw ArchiveError.unsupported }
                    guard unpacked > 0, unpacked <= UInt64(ArchiveCatalog.maximumPathBytes) else { throw ArchiveError.limit }
                    let target = try exact(input, dataOffset, Int(unpacked))
                    guard !target.contains(0), String(data: target, encoding: .utf8) != nil else { throw ArchiveError.invalidPath }
                    guard checksum(target) == crc else { throw ArchiveError.damaged }
                }
                let path = try ArchiveBuilder.normalize(name, directory: directory) ?? "."
                try add(Entry(path: path, kind: kind, size: Int64(unpacked), crc32: crc,
                              dataOffset: dataOffset, packedSize: Int64(packed)), rawPath: name,
                        entries: &entries, budget: budget)
                offset = dataOffset + Int64(packed)
            case 0x7b:
                guard mainSeen else { throw ArchiveError.damaged }
                if flags & 0x0009 != 0 { throw ArchiveError.multiVolume }
                guard flags & ~UInt16(0x4000) == 0 else { throw ArchiveError.unsupported }
                guard size == 7, dataOffset == input.size else { throw ArchiveError.damaged }
                return Metadata(format: .rar4, entries: entries)
            default:
                // This includes comments, recovery records, signatures and
                // subblocks whose contents libarchive would otherwise skip.
                throw ArchiveError.unsupported
            }
        }
        throw ArchiveError.damaged // An explicit end marker is required.
    }

    private static func rar5(_ input: ArchiveInput) throws -> Metadata {
        var offset: Int64 = 8, mainSeen = false, archiveSolid = false
        var entries: [Entry] = [], headerBytes = 0
        var previousDictionary: UInt64?
        let budget = ArchiveBuilder()
        while offset < input.size {
            try Task.checkCancellation()
            let prefix = try exact(input, offset, min(7, Int(input.size - offset)))
            var lengthCursor = Cursor(prefix, position: 4)
            let bodySize = try lengthCursor.vint(maximumBytes: 3)
            guard bodySize >= 2, bodySize <= 2 * 1024 * 1024 else { throw ArchiveError.damaged }
            let size = lengthCursor.position + Int(bodySize)
            let header = try exact(input, offset, size)
            try accountHeader(size, total: &headerBytes)
            guard checksum(header.dropFirst(4)) == little32(header, 0) else { throw ArchiveError.damaged }
            var cursor = Cursor(header, position: lengthCursor.position)
            let type = try cursor.vint(), flags = try cursor.vint()
            if flags & 0x0018 != 0 { throw ArchiveError.multiVolume }
            guard flags & ~UInt64(0x0007) == 0 else { throw ArchiveError.unsupported }
            let extraSize = flags & 1 == 0 ? 0 : try cursor.vint()
            let packed = flags & 2 == 0 ? 0 : try cursor.vint()
            guard extraSize <= UInt64(header.count - cursor.position) else { throw ArchiveError.damaged }
            let extraStart = header.count - Int(extraSize)
            cursor.end = extraStart
            let dataOffset = offset + Int64(size)
            guard packed <= UInt64(input.size - dataOffset) else { throw ArchiveError.damaged }
            switch type {
            case 4:
                throw ArchiveError.encrypted
            case 1:
                guard !mainSeen, offset == 8, flags & 2 == 0 else { throw ArchiveError.damaged }
                let archiveFlags = try cursor.vint()
                if archiveFlags & 3 != 0 { throw ArchiveError.multiVolume }
                guard archiveFlags & ~UInt64(0x14) == 0 else { throw ArchiveError.unsupported }
                archiveSolid = archiveFlags & 4 != 0
                guard cursor.isAtEnd else { throw ArchiveError.damaged }
                try mainExtra(header, start: extraStart)
                mainSeen = true
            case 2:
                guard mainSeen else { throw ArchiveError.damaged }
                let fileFlags = try cursor.vint(), unpacked = try cursor.vint(), attributes = try cursor.vint()
                guard fileFlags & ~UInt64(7) == 0 else { throw ArchiveError.unsupported }
                let directory = fileFlags & 1 != 0
                if fileFlags & 2 != 0 { _ = try cursor.u32() }
                let crc = fileFlags & 4 == 0 ? nil : try cursor.u32()
                let compression = try cursor.vint(), host = try cursor.vint(), nameSize = try cursor.vint()
                guard compression & 0x3f == 0, compression & ~UInt64(0x7fff) == 0,
                      (compression >> 7) & 7 <= 5 else { throw ArchiveError.unsupported }
                let dictionaryBits = (compression >> 10) & 31
                guard dictionaryBits <= 9 else { throw ArchiveError.limit } // 128 KiB << 9 == 64 MiB.
                let dictionary = UInt64(128 * 1024) << dictionaryBits
                if compression & 0x40 != 0 {
                    guard !directory, archiveSolid, previousDictionary == dictionary else { throw ArchiveError.damaged }
                }
                guard unpacked <= UInt64(ArchiveCatalog.maximumFileBytes) else { throw ArchiveError.limit }
                if directory {
                    guard unpacked == 0, packed == 0 else { throw ArchiveError.damaged }
                } else {
                    guard flags & 2 != 0 else { throw ArchiveError.damaged }
                    if (compression >> 7) & 7 == 0, packed != unpacked { throw ArchiveError.damaged }
                    previousDictionary = dictionary
                }
                guard nameSize > 0, nameSize <= UInt64(ArchiveCatalog.maximumPathBytes) else { throw ArchiveError.limit }
                let nameBytes = try cursor.take(Int(nameSize))
                guard let name = String(data: nameBytes, encoding: .utf8), !name.contains("\0"),
                      !name.unicodeScalars.contains(where: { $0.value == 0xfffe }) else { throw ArchiveError.invalidPath }
                guard cursor.isAtEnd else { throw ArchiveError.damaged }
                let kind = try rar5Kind(host: host, attributes: attributes, directory: directory)
                try fileExtra(header, start: extraStart)
                let path = try ArchiveBuilder.normalize(name, directory: directory) ?? "."
                try add(Entry(path: path, kind: kind, size: Int64(unpacked), crc32: crc,
                              dataOffset: dataOffset, packedSize: Int64(packed)), rawPath: name,
                        entries: &entries, budget: budget)
            case 5:
                guard mainSeen, flags & 3 == 0 else { throw ArchiveError.damaged }
                let endFlags = try cursor.vint()
                if endFlags & 1 != 0 { throw ArchiveError.multiVolume }
                guard endFlags == 0 else { throw ArchiveError.unsupported }
                guard cursor.isAtEnd, dataOffset == input.size else { throw ArchiveError.damaged }
                return Metadata(format: .rar5, entries: entries)
            default:
                throw ArchiveError.unsupported
            }
            offset = dataOffset + Int64(packed)
        }
        throw ArchiveError.damaged
    }

    private static func mainExtra(_ data: Data, start: Int) throws {
        var cursor = Cursor(data, position: start)
        var records = 0
        while !cursor.isAtEnd {
            records += 1
            guard records <= 1 else { throw ArchiveError.unsupported }
            var record = try extraRecord(&cursor)
            guard try record.vint() == 1 else { throw ArchiveError.unsupported }
            let flags = try record.vint()
            guard flags & ~UInt64(3) == 0 else { throw ArchiveError.unsupported }
            for flag: UInt64 in [1, 2] where flags & flag != 0 {
                // Nonzero references point at unsupported service blocks.
                guard try record.vint() == 0 else { throw ArchiveError.unsupported }
            }
            guard record.isAtEnd else { throw ArchiveError.damaged }
        }
    }

    private static func fileExtra(_ data: Data, start: Int) throws {
        var cursor = Cursor(data, position: start), seen = Set<UInt64>()
        while !cursor.isAtEnd {
            var record = try extraRecord(&cursor)
            let type = try record.vint()
            guard seen.insert(type).inserted else { throw ArchiveError.damaged }
            switch type {
            case 1: throw ArchiveError.encrypted
            case 3:
                let flags = try record.vint()
                guard flags & ~UInt64(31) == 0, flags & 16 == 0 || flags & 1 != 0 else { throw ArchiveError.unsupported }
                let unix = flags & 1 != 0
                for flag: UInt64 in [2, 4, 8] where flags & flag != 0 {
                    _ = try record.take(unix ? 4 : 8)
                }
                if flags & 16 != 0 {
                    for flag: UInt64 in [2, 4, 8] where flags & flag != 0 {
                        guard try record.u32() < 1_000_000_000 else { throw ArchiveError.damaged }
                    }
                }
            case 6:
                let flags = try record.vint()
                guard flags & ~UInt64(15) == 0 else { throw ArchiveError.unsupported }
                for flag: UInt64 in [1, 2] where flags & flag != 0 {
                    let count = try record.vint()
                    guard count <= 255 else { throw ArchiveError.limit }
                    _ = try record.take(Int(count))
                }
                for flag: UInt64 in [4, 8] where flags & flag != 0 { _ = try record.vint() }
            default:
                // BLAKE2sp hashes, file versions, redirections, service data and
                // unknown records need separate verification before admission.
                throw ArchiveError.unsupported
            }
            guard record.isAtEnd else { throw ArchiveError.damaged }
        }
    }

    private static func extraRecord(_ cursor: inout Cursor) throws -> Cursor {
        let size = try cursor.vint()
        guard size > 0, size <= UInt64(cursor.end - cursor.position) else { throw ArchiveError.damaged }
        let result = Cursor(cursor.data, position: cursor.position, end: cursor.position + Int(size))
        cursor.position += Int(size)
        return result
    }

    private static func rar4Kind(host: UInt8, attributes: UInt32, directory: Bool) throws -> ArchiveEntryKind {
        switch host {
        case 0...2:
            guard (attributes & 0x10 != 0) == directory else { throw ArchiveError.damaged }
            return directory ? .directory : .file
        case 3...5:
            switch attributes & 0xf000 {
            case 0x4000 where directory: return .directory
            case 0x8000 where !directory: return .file
            case 0xa000 where !directory: return .symbolicLink
            default: throw ArchiveError.unsupported
            }
        default: throw ArchiveError.unsupported
        }
    }

    private static func rar5Kind(host: UInt64, attributes: UInt64, directory: Bool) throws -> ArchiveEntryKind {
        guard attributes <= UInt64(UInt32.max) else { throw ArchiveError.unsupported }
        if host == 0 {
            guard (attributes & 0x10 != 0) == directory else { throw ArchiveError.damaged }
        } else if host == 1 {
            guard attributes & 0xf000 == (directory ? 0x4000 : 0x8000) else { throw ArchiveError.unsupported }
        } else { throw ArchiveError.unsupported }
        return directory ? .directory : .file
    }

    private static func rar4Name(_ bytes: Data, unicode: Bool) throws -> String {
        guard unicode, let separator = bytes.firstIndex(of: 0) else {
            guard !bytes.contains(0), let name = String(data: bytes, encoding: .utf8) else { throw ArchiveError.invalidPath }
            return nameReplacingRAR4Separators(name)
        }
        let plain = Array(bytes.prefix(separator))
        var encoded = Cursor(bytes, position: separator + 1)
        let high = UInt16(try encoded.byte()) << 8
        var units: [UInt16] = []
        while !encoded.isAtEnd {
            let controls = try encoded.byte()
            guard !encoded.isAtEnd else { throw ArchiveError.damaged }
            for shift in stride(from: 6, through: 0, by: -2) {
                if encoded.isAtEnd { break }
                switch (controls >> shift) & 3 {
                case 0: units.append(UInt16(try encoded.byte()))
                case 1: units.append(high | UInt16(try encoded.byte()))
                case 2: units.append(try encoded.u16())
                default:
                    let length = try encoded.byte()
                    let correction = length & 0x80 == 0 ? 0 : try encoded.byte()
                    let amount = Int(length & 0x7f) + 2
                    guard units.count <= plain.count, amount <= plain.count - units.count else { throw ArchiveError.damaged }
                    for _ in 0..<amount {
                        let low = plain[units.count] &+ correction
                        units.append((length & 0x80 == 0 ? 0 : high) | UInt16(low))
                    }
                }
                guard units.count <= ArchiveCatalog.maximumPathBytes else { throw ArchiveError.limit }
            }
        }
        guard !units.isEmpty, !units.contains(0) else { throw ArchiveError.invalidPath }
        let name = String(decoding: units, as: UTF16.self)
        // String's repairing decoder must not silently replace invalid UTF-16.
        guard Array(name.utf16) == units else { throw ArchiveError.invalidPath }
        return nameReplacingRAR4Separators(name)
    }

    private static func nameReplacingRAR4Separators(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    private static func add(_ entry: Entry, rawPath: String, entries: inout [Entry], budget: ArchiveBuilder) throws {
        guard entries.count < ArchiveCatalog.maximumEntries else { throw ArchiveError.limit }
        try budget.add(rawPath: rawPath, kind: entry.kind, size: entry.size, digest: nil, issue: nil)
        try budget.account(entry.size, fileBytes: entry.size)
        entries.append(entry)
    }

    private static func accountHeader(_ count: Int, total: inout Int) throws {
        guard count <= 64 * 1024 * 1024 - total else { throw ArchiveError.limit }
        total += count
    }

    private static func exact(_ input: ArchiveInput, _ offset: Int64, _ count: Int) throws -> Data {
        guard offset >= 0, offset <= input.size, count >= 0, Int64(count) <= input.size - offset else { throw ArchiveError.damaged }
        var data = Data()
        while data.count < count {
            data.append(try input.read(offset: offset + Int64(data.count), count: min(count - data.count, 1024 * 1024)))
        }
        return data
    }
    private static func little16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func little32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(little16(data, offset)) | UInt32(little16(data, offset + 2)) << 16
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
        return value
    }
    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = .max
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 255)] }
        return ~crc
    }

    private struct Cursor {
        let data: Data
        var position: Int
        var end: Int
        init(_ data: Data, position: Int = 0, end: Int? = nil) {
            self.data = data; self.position = position; self.end = end ?? data.count
        }
        var isAtEnd: Bool { position == end }
        mutating func take(_ count: Int) throws -> Data {
            guard position <= end, count >= 0, count <= end - position else { throw ArchiveError.damaged }
            let result = data.subdata(in: position..<(position + count))
            position += count
            return result
        }
        mutating func byte() throws -> UInt8 {
            guard position < end else { throw ArchiveError.damaged }
            defer { position += 1 }
            return data[position]
        }
        mutating func u16() throws -> UInt16 {
            let bytes = try take(2)
            return little16(bytes, 0)
        }
        mutating func u32() throws -> UInt32 {
            let bytes = try take(4)
            return little32(bytes, 0)
        }
        mutating func vint(maximumBytes: Int = 10) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<maximumBytes {
                let byte = try byte()
                if index == 9, byte > 1 { throw ArchiveError.damaged }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw ArchiveError.damaged
        }
    }
}

import Foundation
import Darwin

/// A bounded, deliberately small 7z grammar, checked before libarchive sees
/// any coder properties. This is not a content decoder: only encoded metadata
/// is decoded here, using the system liblzma, with fixed input/output budgets.
/// Grammar: 7-Zip's DOC/7zFormat.txt; liblzma ABI: xz 5.4.3 api/lzma/lzma12.h.
enum Archive7z {
    static let maximumDictionaryBytes: UInt64 = 64 * 1024 * 1024
    private static let maximumHeaderBytes = 1024 * 1024

    struct Entry {
        let rawPath: String
        let kind: ArchiveEntryKind
        let size: Int64
        let crc32: UInt32?
        var isDirectory: Bool { kind == .directory }
    }
    struct Metadata {
        let entries: [Entry]
        let declaredExpandedBytes: Int64
        let checksumGroups: [ChecksumGroup]
        var entryCount: Int { entries.count }
    }
    /// A Folder CRC covers the concatenation of its substreams, even when
    /// individual substream CRCs are absent. Paths are normalized reader keys.
    struct ChecksumGroup {
        let paths: [String]
        let size: Int64
        let crc32: UInt32
    }

    static func validate(_ input: ArchiveInput) throws -> Metadata {
        try Task.checkCancellation()
        guard input.size >= 32 else { throw ArchiveError.damaged }
        guard input.size <= ArchiveCatalog.maximumSourceBytes else { throw ArchiveError.limit }
        let start = try bytes(input, at: 0, count: 32)
        guard Array(start.prefix(6)) == [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
              crc(start[12..<32]) == little32(start, 8) else { throw ArchiveError.damaged }
        guard start[6] == 0, start[7] <= 4 else { throw ArchiveError.unsupported }
        let offset = little64(start, 12), count = little64(start, 20)
        guard count <= UInt64(maximumHeaderBytes) else { throw ArchiveError.limit }
        guard offset <= UInt64(input.size - 32), count == UInt64(input.size - 32) - offset else {
            throw ArchiveError.damaged
        }
        if count == 0 {
            guard offset == 0, little32(start, 28) == 0 else { throw ArchiveError.damaged }
            return Metadata(entries: [], declaredExpandedBytes: 0, checksumGroups: [])
        }
        let nextOffset = Int64(offset) + 32
        let next = try bytes(input, at: nextOffset, count: Int(count))
        guard crc(next) == little32(start, 28) else { throw ArchiveError.damaged }
        var cursor = Cursor(next)
        let marker = try cursor.byte()
        let metadata: Metadata
        if marker == 0x17 { // EncodedHeader
            let encoded = try streams(&cursor, header: true)
            guard cursor.finished, encoded.folders.count == 1, encoded.packSizes.count == 1,
                  encoded.folders[0].coders.count == 1, encoded.substreams.count == 1 else { throw ArchiveError.unsupported }
            guard encoded.packSizes[0] <= UInt64(maximumHeaderBytes) else { throw ArchiveError.limit }
            let packedStart = try encoded.range(end: UInt64(nextOffset))
            guard packedStart + encoded.packSizes[0] == UInt64(nextOffset) else { throw ArchiveError.damaged }
            let packed = try bytes(input, at: Int64(packedStart), count: Int(encoded.packSizes[0]))
            if let checksum = encoded.packCRCs[0], crc(packed) != checksum { throw ArchiveError.damaged }
            let folder = encoded.folders[0]
            guard let checksum = folder.crc32 else { throw ArchiveError.unsupported }
            let decoded = try decodeHeader(packed, coder: folder.coders[0], size: Int(folder.size))
            guard crc(decoded) == checksum else { throw ArchiveError.damaged }
            var decodedCursor = Cursor(decoded)
            guard try decodedCursor.byte() == 0x01 else { throw ArchiveError.damaged }
            metadata = try header(&decodedCursor, dataEnd: packedStart, input: input)
            guard decodedCursor.finished else { throw ArchiveError.damaged }
        } else {
            guard marker == 0x01 else { throw ArchiveError.unsupported }
            metadata = try header(&cursor, dataEnd: UInt64(nextOffset), input: input)
            guard cursor.finished else { throw ArchiveError.damaged }
        }
        try input.stamp.verify(descriptor: input.descriptor)
        return metadata
    }

    private struct Coder {
        let method: UInt64
        let properties: [UInt8]
    }
    private struct Folder {
        let coders: [Coder]
        var size: UInt64 = 0
        var crc32: UInt32?
    }
    private struct Substream {
        let size: UInt64
        var crc32: UInt32?
        let folderIndex: Int
    }
    private struct Streams {
        var packPosition: UInt64 = 0
        var packSizes: [UInt64] = []
        var packCRCs: [UInt32?] = []
        var folders: [Folder] = []
        var substreams: [Substream] = []
        func range(end: UInt64) throws -> UInt64 {
            guard end >= 32, packPosition <= end - 32 else { throw ArchiveError.damaged }
            let begin = 32 + packPosition
            var position = begin
            for size in packSizes {
                guard size <= end - position else { throw ArchiveError.damaged }
                position += size
            }
            guard position == end else { throw ArchiveError.damaged }
            return begin
        }
    }

    private static func streams(_ cursor: inout Cursor, header: Bool) throws -> Streams {
        var result = Streams()
        var tag = try cursor.byte()
        guard tag == 0x06 else { throw ArchiveError.unsupported }
        result.packPosition = try cursor.number()
        let packedCount = try cursor.count(maximum: ArchiveCatalog.maximumEntries)
        guard packedCount > 0, try cursor.byte() == 0x09 else { throw ArchiveError.damaged }
        for _ in 0..<packedCount { result.packSizes.append(try cursor.number()) }
        tag = try cursor.byte()
        if tag == 0x0a {
            result.packCRCs = try cursor.digests(packedCount)
            tag = try cursor.byte()
        } else { result.packCRCs = Array(repeating: nil, count: packedCount) }
        guard tag == 0, try cursor.byte() == 0x07, try cursor.byte() == 0x0b else { throw ArchiveError.damaged }
        let folderCount = try cursor.count(maximum: header ? 1 : ArchiveCatalog.maximumEntries)
        guard folderCount > 0, folderCount == packedCount else { throw ArchiveError.unsupported }
        guard try cursor.byte() == 0 else { throw ArchiveError.unsupported } // External folder metadata.
        for _ in 0..<folderCount { result.folders.append(try folder(&cursor, header: header)) }
        guard try cursor.byte() == 0x0c else { throw ArchiveError.damaged }
        let maximum = header ? UInt64(maximumHeaderBytes) : UInt64(ArchiveCatalog.maximumExpandedBytes)
        var total: UInt64 = 0
        for index in result.folders.indices {
            let size = try cursor.number()
            guard size <= maximum - total else { throw ArchiveError.limit }
            total += size
            // All permitted filters preserve length, so every output agrees.
            for _ in 1..<result.folders[index].coders.count {
                guard try cursor.number() == size else { throw ArchiveError.damaged }
            }
            result.folders[index].size = size
        }
        tag = try cursor.byte()
        if tag == 0x0a {
            let digests = try cursor.digests(folderCount)
            for index in result.folders.indices { result.folders[index].crc32 = digests[index] }
            tag = try cursor.byte()
        }
        guard tag == 0 else { throw ArchiveError.damaged }
        tag = try cursor.byte()
        if tag == 0x08 {
            result.substreams = try substreams(&cursor, folders: result.folders, header: header)
            tag = try cursor.byte()
        } else {
            result.substreams = result.folders.enumerated().map {
                Substream(size: $0.element.size, crc32: $0.element.crc32, folderIndex: $0.offset)
            }
        }
        guard tag == 0 else { throw ArchiveError.unsupported }
        let fileMaximum = header ? UInt64(maximumHeaderBytes) : UInt64(ArchiveCatalog.maximumFileBytes)
        guard result.substreams.allSatisfy({ $0.size <= fileMaximum }) else { throw ArchiveError.limit }
        return result
    }

    private static func folder(_ cursor: inout Cursor, header: Bool) throws -> Folder {
        let count = try cursor.count(maximum: 4)
        guard count > 0 else { throw ArchiveError.damaged }
        var coders: [Coder] = []
        for _ in 0..<count {
            let flags = try cursor.byte(), methodBytes = Int(flags & 15)
            guard methodBytes > 0, methodBytes <= 8, flags & 0xc0 == 0 else { throw ArchiveError.unsupported }
            var method: UInt64 = 0
            for byte in try cursor.take(methodBytes) { method = (method << 8) | UInt64(byte) }
            if method == 0x06f10701 { throw ArchiveError.encrypted }
            if flags & 0x10 != 0 {
                guard try cursor.number() == 1, try cursor.number() == 1 else { throw ArchiveError.unsupported }
            }
            let properties = flags & 0x20 == 0 ? [] : try cursor.take(cursor.count(maximum: 16))
            let coder = Coder(method: method, properties: properties)
            try validateCoder(coder)
            coders.append(coder)
        }
        // This subset only accepts one compressor followed by one optional
        // length-preserving filter, never a multi-input graph or BCJ2 buffers.
        guard count <= (header ? 1 : 2), [0, 0x030101, 0x21].contains(coders[0].method) else {
            throw ArchiveError.unsupported
        }
        if count == 2 {
            guard ![0, 0x030101, 0x21].contains(coders[1].method),
                  try cursor.number() == 1, try cursor.number() == 0 else { throw ArchiveError.unsupported }
        }
        return Folder(coders: coders)
    }

    private static func validateCoder(_ coder: Coder) throws {
        let p = coder.properties
        switch coder.method {
        case 0: guard p.isEmpty else { throw ArchiveError.damaged }
        case 0x030101:
            guard p.count == 5, p[0] < 225 else { throw ArchiveError.damaged }
            let lc = p[0] % 9, lp = (p[0] / 9) % 5
            guard lc + lp <= 4 else { throw ArchiveError.unsupported }
            guard UInt64(little32(p, 1)) <= maximumDictionaryBytes else { throw ArchiveError.limit }
        case 0x21:
            guard p.count == 1, p[0] <= 40 else { throw ArchiveError.damaged }
            guard p[0] <= 28 else { throw ArchiveError.limit }
        case 0x03: guard p.count == 1 else { throw ArchiveError.damaged } // Delta distance minus one.
        case 0x03030103, 0x03030205, 0x03030401, 0x03030501, 0x03030701, 0x03030805, 0x0a:
            // x86, PowerPC, IA64, ARM, ARM-Thumb, SPARC and ARM64 BCJ.
            guard p.isEmpty || p.count == 4 else { throw ArchiveError.damaged }
        default: throw ArchiveError.unsupported
        }
    }

    private static func substreams(_ cursor: inout Cursor, folders: [Folder], header: Bool) throws -> [Substream] {
        var counts = Array(repeating: 1, count: folders.count), tag = try cursor.byte()
        if tag == 0x0d {
            var total = 0
            for index in counts.indices {
                counts[index] = try cursor.count(maximum: (header ? 1 : ArchiveCatalog.maximumEntries) - total)
                total += counts[index]
            }
            tag = try cursor.byte()
        }
        var result: [Substream] = [], digestIndexes: [Int] = []
        for index in folders.indices {
            let folder = folders[index], count = counts[index]
            if count == 0 {
                guard folder.size == 0 else { throw ArchiveError.damaged }
                continue
            }
            if count > 1, tag != 0x09 { throw ArchiveError.damaged }
            var remaining = folder.size
            for subindex in 0..<count {
                let size = subindex == count - 1 ? remaining : try cursor.number()
                guard size <= remaining else { throw ArchiveError.damaged }
                remaining -= size
                let checksum = count == 1 ? folder.crc32 : nil
                if checksum == nil { digestIndexes.append(result.count) }
                result.append(Substream(size: size, crc32: checksum, folderIndex: index))
            }
        }
        if tag == 0x09 { tag = try cursor.byte() }
        if tag == 0x0a {
            let values = try cursor.digests(digestIndexes.count)
            for (index, value) in zip(digestIndexes, values) { result[index].crc32 = value }
            tag = try cursor.byte()
        }
        guard tag == 0 else { throw ArchiveError.unsupported }
        return result
    }

    private static func header(_ cursor: inout Cursor, dataEnd: UInt64, input: ArchiveInput) throws -> Metadata {
        var tag = try cursor.byte(), streamsInfo = Streams()
        // ArchiveProperties and AdditionalStreams may hide metadata streams;
        // neither is needed by ordinary 7zz archives in this subset.
        if tag == 0x04 {
            streamsInfo = try streams(&cursor, header: false)
            guard streamsInfo.packPosition == 0 else { throw ArchiveError.unsupported }
            let begin = try streamsInfo.range(end: dataEnd)
            try verifyPackedChecksums(streamsInfo, input: input, begin: begin)
            tag = try cursor.byte()
        } else if dataEnd != 32 { throw ArchiveError.damaged }
        if tag == 0 {
            guard streamsInfo.substreams.isEmpty else { throw ArchiveError.damaged }
            let groups = streamsInfo.folders.compactMap { folder -> ChecksumGroup? in
                guard let checksum = folder.crc32 else { return nil }
                return ChecksumGroup(paths: [], size: Int64(folder.size), crc32: checksum)
            }
            return Metadata(entries: [], declaredExpandedBytes: 0, checksumGroups: groups)
        }
        guard tag == 0x05 else { throw ArchiveError.unsupported }
        let count = try cursor.count(maximum: ArchiveCatalog.maximumEntries)
        var names: [String]?, attributes = Array<UInt32?>(repeating: nil, count: count)
        var empty = Array(repeating: false, count: count), emptyFiles: [Bool] = []
        var properties = Set<UInt8>()
        while true {
            tag = try cursor.byte()
            if tag == 0 { break }
            guard tag == 0x19 || properties.insert(tag).inserted else { throw ArchiveError.damaged }
            let size = try cursor.count(maximum: maximumHeaderBytes)
            var property = Cursor(try cursor.take(size))
            switch tag {
            case 0x0e: empty = try property.bools(count)
            case 0x0f:
                guard properties.contains(0x0e) else { throw ArchiveError.damaged }
                emptyFiles = try property.bools(empty.filter { $0 }.count)
            case 0x10:
                guard properties.contains(0x0e) else { throw ArchiveError.damaged }
                guard try property.bools(empty.filter { $0 }.count).allSatisfy({ !$0 }) else { throw ArchiveError.unsupported }
            case 0x11:
                guard try property.byte() == 0 else { throw ArchiveError.unsupported }
                var parsed: [String] = []
                for _ in 0..<count {
                    var units: [UInt8] = []
                    while true {
                        let pair = try property.take(2)
                        if pair == [0, 0] { break }
                        guard units.count < ArchiveCatalog.maximumPathBytes * 2 else { throw ArchiveError.invalidPath }
                        units += pair
                    }
                    guard !units.isEmpty, let name = String(data: Data(units), encoding: .utf16LittleEndian),
                          name.utf8.count <= ArchiveCatalog.maximumPathBytes else { throw ArchiveError.invalidPath }
                    parsed.append(name)
                }
                names = parsed
            case 0x12, 0x13, 0x14: // Creation, access, modification times.
                let defined = try property.defined(count)
                guard try property.byte() == 0 else { throw ArchiveError.unsupported }
                _ = try property.take(defined.filter { $0 }.count * 8)
            case 0x15:
                // All-defined attributes avoid an older system reader's
                // different bitmap/external ordering for partial attributes.
                guard try property.byte() == 1, try property.byte() == 0 else { throw ArchiveError.unsupported }
                for index in attributes.indices { attributes[index] = try property.u32() }
            case 0x19: // Defined zero padding, not arbitrary ignored properties.
                guard try property.take(size).allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
            default: throw ArchiveError.unsupported
            }
            guard property.finished else { throw ArchiveError.damaged }
        }
        guard try cursor.byte() == 0 else { throw ArchiveError.damaged }
        guard count == 0 || names != nil else { throw ArchiveError.invalidPath }
        guard count - empty.filter({ $0 }).count == streamsInfo.substreams.count else { throw ArchiveError.damaged }
        var entries: [Entry] = [], streamIndex = 0, emptyIndex = 0, total: Int64 = 0, paths = Set<String>()
        var groupPaths = Array(repeating: [String](), count: streamsInfo.folders.count)
        for index in 0..<count {
            try Task.checkCancellation()
            var kind: ArchiveEntryKind = .file
            if empty[index] {
                kind = emptyFiles.isEmpty || !emptyFiles[emptyIndex] ? .directory : .file
                emptyIndex += 1
            }
            if let attr = attributes[index] {
                if attr & 0x8000 != 0 {
                    switch mode_t(attr >> 16) & mode_t(S_IFMT) {
                    case mode_t(S_IFREG): kind = .file
                    case mode_t(S_IFDIR): kind = .directory
                    case mode_t(S_IFLNK): kind = .symbolicLink
                    case 0: break
                    default: kind = .other
                    }
                } else if attr & 0x10 != 0 { kind = .directory }
            }
            let substream = empty[index] ? Substream(size: 0, crc32: nil, folderIndex: -1) : streamsInfo.substreams[streamIndex]
            if !empty[index] { streamIndex += 1 }
            if kind == .directory, substream.size != 0 { throw ArchiveError.damaged }
            if kind != .file, kind != .directory, substream.size > 4096 { throw ArchiveError.limit }
            let name = names![index]
            let path = try ArchiveBuilder.normalize(name, directory: kind == .directory) ?? "."
            guard paths.insert(path).inserted else { throw ArchiveError.duplicatePath(path) }
            if !empty[index] { groupPaths[substream.folderIndex].append(path) }
            total += Int64(substream.size)
            entries.append(Entry(rawPath: name, kind: kind, size: Int64(substream.size), crc32: substream.crc32))
        }
        let groups = streamsInfo.folders.enumerated().compactMap { index, folder -> ChecksumGroup? in
            guard let checksum = folder.crc32 else { return nil }
            return ChecksumGroup(paths: groupPaths[index], size: Int64(folder.size), crc32: checksum)
        }
        return Metadata(entries: entries, declaredExpandedBytes: total, checksumGroups: groups)
    }

    /// libarchive does not validate the optional PackInfo CRCs. Check their
    /// physical byte ranges independently before decoding, without buffering a
    /// packed stream (a valid source can be much larger than the header budget).
    private static func verifyPackedChecksums(_ streams: Streams, input: ArchiveInput, begin: UInt64) throws {
        var position = begin
        for index in streams.packSizes.indices {
            let end = position + streams.packSizes[index]
            if let expected = streams.packCRCs[index] {
                var state: UInt32 = 0xffffffff
                while position < end {
                    let count = Int(min(end - position, 64 * 1024))
                    for byte in try input.read(offset: Int64(position), count: count) {
                        state = (state >> 8) ^ crcTable[Int((state ^ UInt32(byte)) & 255)]
                    }
                    position += UInt64(count)
                }
                guard state ^ 0xffffffff == expected else { throw ArchiveError.damaged }
            }
            position = end
        }
    }

    private static func decodeHeader(_ packed: [UInt8], coder: Coder, size: Int) throws -> [UInt8] {
        guard size > 0, size <= maximumHeaderBytes, packed.count <= maximumHeaderBytes else { throw ArchiveError.limit }
        if coder.method == 0 {
            guard packed.count == size else { throw ArchiveError.damaged }
            return packed
        }
        // Both supported macOS architectures use 64-bit pointers. lzma_filter
        // is { uint64_t id; void *options; }, followed by LZMA_VLI_UNKNOWN.
        let library = try ArchiveLibrary(path: "/usr/lib/liblzma.5.dylib")
        let properties = try library.function("lzma_properties_decode", (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafePointer<UInt8>?, Int) -> Int32).self)
        let decode = try library.function("lzma_raw_buffer_decode", (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int) -> Int32).self)
        let free = try library.function("lzma_filters_free", (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void).self)
        let filters = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        filters.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        defer { free(filters, nil); filters.deallocate() }
        // LZMA1EXT accepts 7z's external output size, without requiring an EOS
        // marker. Plain LZMA1 raw_buffer_decode rejects ordinary 7zz headers.
        let method: UInt64 = coder.method == 0x030101 ? 0x4000000000000002 : 0x21
        filters.storeBytes(of: method, as: UInt64.self)
        filters.storeBytes(of: UInt64.max, toByteOffset: 16, as: UInt64.self)
        let status = coder.properties.withUnsafeBufferPointer { properties(filters, nil, $0.baseAddress, $0.count) }
        guard status == 0 else { throw ArchiveError.unsupported }
        if coder.method == 0x030101 {
            guard let options = filters.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self) else { throw ArchiveError.unavailable }
            // ABI fields after dict/preset/lc/lp/pb/mode/nice_len/mf/depth:
            // ext_flags (ALLOW_EOPM), ext_size_low, ext_size_high.
            options.storeBytes(of: UInt32(1), toByteOffset: 48, as: UInt32.self)
            options.storeBytes(of: UInt32(size), toByteOffset: 52, as: UInt32.self)
            options.storeBytes(of: UInt32(0), toByteOffset: 56, as: UInt32.self)
        }
        var output = [UInt8](repeating: 0, count: size), inputPosition = 0, outputPosition = 0
        let result = packed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                decode(filters, nil, source.baseAddress, &inputPosition, source.count, destination.baseAddress, &outputPosition, destination.count)
            }
        }
        guard result == 0, inputPosition == packed.count, outputPosition == size else { throw ArchiveError.damaged }
        try Task.checkCancellation()
        return output
    }

    private struct Cursor {
        let data: [UInt8]
        var position = 0
        init(_ data: [UInt8]) { self.data = data }
        var finished: Bool { position == data.count }
        mutating func byte() throws -> UInt8 {
            guard position < data.count else { throw ArchiveError.damaged }
            defer { position += 1 }
            return data[position]
        }
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= data.count - position else { throw ArchiveError.damaged }
            defer { position += count }
            return Array(data[position..<(position + count)])
        }
        mutating func number() throws -> UInt64 {
            let first = try byte()
            var value: UInt64 = 0, mask: UInt8 = 0x80
            for index in 0..<8 {
                if first & mask == 0 { return value | (UInt64(first & (mask - 1)) << (index * 8)) }
                value |= UInt64(try byte()) << (index * 8)
                mask >>= 1
            }
            return value
        }
        mutating func count(maximum: Int) throws -> Int {
            let value = try number()
            guard value <= UInt64(maximum) else { throw ArchiveError.limit }
            return Int(value)
        }
        mutating func u32() throws -> UInt32 { Archive7z.little32(try take(4), 0) }
        mutating func bools(_ count: Int) throws -> [Bool] {
            let bytes = try take((count + 7) / 8)
            if count % 8 != 0, let last = bytes.last {
                guard last & UInt8((1 << (8 - count % 8)) - 1) == 0 else { throw ArchiveError.damaged }
            }
            return (0..<count).map { bytes[$0 / 8] & (0x80 >> ($0 % 8)) != 0 }
        }
        mutating func defined(_ count: Int) throws -> [Bool] {
            let all = try byte()
            guard all <= 1 else { throw ArchiveError.damaged }
            return all == 1 ? Array(repeating: true, count: count) : try bools(count)
        }
        mutating func digests(_ count: Int) throws -> [UInt32?] {
            let bits = try defined(count)
            var result: [UInt32?] = []
            for bit in bits { result.append(bit ? try u32() : nil) }
            return result
        }
    }
    private static func bytes(_ input: ArchiveInput, at offset: Int64, count: Int) throws -> [UInt8] {
        let data = try input.read(offset: offset, count: count)
        guard data.count == count else { throw ArchiveError.damaged }
        return Array(data)
    }
    private static func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func little64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(little32(bytes, offset)) | UInt64(little32(bytes, offset + 4)) << 32
    }
    private static let crcTable: [UInt32] = (0..<256).map {
        var value = UInt32($0)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    private static func crc<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var value: UInt32 = 0xffffffff
        for byte in bytes { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 255)] }
        return value ^ 0xffffffff
    }
}

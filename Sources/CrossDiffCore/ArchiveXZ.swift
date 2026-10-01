import Foundation

/// Preflight the supported XZ subset before libarchive can allocate a decoder
/// dictionary. This does not decode contents or replace libarchive's data checks.
/// Format: https://tukaani.org/xz/xz-file-format.txt (1.2.1), sections 1–5.
/// LZMA2 framing: https://github.com/tukaani-project/xz/blob/master/src/liblzma/lzma/lzma2_decoder.c
/// Only one stream, one LZMA2 filter per block, and no trailing stream padding.
enum ArchiveXZ {
    static let maximumDictionaryBytes: Int64 = 64 * 1024 * 1024
    private static let maximumIndexBytes: Int64 = 1024 * 1024
    private static let maximumBlocks: Int64 = 10_000
    private static let maximumChunks = 100_000
    private static var maximumExpandedBytes: Int64 { ArchiveCatalog.maximumExpandedBytes + 32 * 1024 * 1024 }

    static func validate(_ input: ArchiveInput) throws {
        try Task.checkCancellation()
        guard input.size >= 32, input.size <= ArchiveCatalog.maximumSourceBytes, input.size % 4 == 0 else { throw ArchiveError.damaged }
        let header = try bytes(input, at: 0, count: 12)
        let footer = try bytes(input, at: input.size - 12, count: 12)
        guard Array(header.prefix(6)) == [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0],
              footer[10] == 0x59, footer[11] == 0x5a,
              header[6] == 0, footer[8] == header[6], footer[9] == header[7],
              crc32(header[6..<8]) == little32(header, 8),
              crc32(footer[4..<10]) == little32(footer, 0) else { throw ArchiveError.damaged }
        let checkBytes: Int64
        switch header[7] {
        case 1: checkBytes = 4
        case 4: checkBytes = 8
        case 10: checkBytes = 32
        default: throw ArchiveError.unsupported // No-check and reserved checks are outside this subset.
        }
        let indexBytes = (Int64(little32(footer, 4)) + 1) * 4
        guard indexBytes >= 8, indexBytes <= maximumIndexBytes, indexBytes <= input.size - 24 else { throw ArchiveError.limit }
        let indexOffset = input.size - 12 - indexBytes
        let index = try bytes(input, at: indexOffset, count: Int(indexBytes))
        guard index[0] == 0, crc32(index[0..<(index.count - 4)]) == little32(index, index.count - 4) else { throw ArchiveError.damaged }
        var cursor = 1
        let count = try integer(index, cursor: &cursor, end: index.count - 4)
        guard count <= maximumBlocks else { throw ArchiveError.limit }
        var blockOffset: Int64 = 12, expanded: Int64 = 0, chunks = 0
        let window = Window(input)
        for _ in 0..<Int(count) {
            try Task.checkCancellation()
            let unpadded = try integer(index, cursor: &cursor, end: index.count - 4)
            let unpacked = try integer(index, cursor: &cursor, end: index.count - 4)
            guard unpacked <= maximumExpandedBytes - expanded else { throw ArchiveError.limit }
            expanded += unpacked
            // All arithmetic below is bounded by the source size before rounding/addition.
            guard blockOffset <= indexOffset, unpadded > 0, unpadded <= indexOffset - blockOffset else { throw ArchiveError.damaged }
            let padded = (unpadded + 3) / 4 * 4
            guard padded <= indexOffset - blockOffset else { throw ArchiveError.damaged }
            let encodedHeader = try window.byte(at: blockOffset)
            guard encodedHeader != 0 else { throw ArchiveError.damaged }
            let headerBytes = (Int(encodedHeader) + 1) * 4
            guard Int64(headerBytes) + checkBytes < unpadded else { throw ArchiveError.damaged }
            let blockHeader = try bytes(input, at: blockOffset, count: headerBytes)
            let headerEnd = headerBytes - 4
            guard crc32(blockHeader[0..<headerEnd]) == little32(blockHeader, headerEnd) else { throw ArchiveError.damaged }
            let flags = blockHeader[1]
            guard flags & 0x3f == 0 else { throw ArchiveError.unsupported } // One filter; no reserved bits.
            let compressed = unpadded - Int64(headerBytes) - checkBytes
            var field = 2
            if flags & 0x40 != 0 {
                guard try integer(blockHeader, cursor: &field, end: headerEnd) == compressed else { throw ArchiveError.damaged }
            }
            if flags & 0x80 != 0 {
                guard try integer(blockHeader, cursor: &field, end: headerEnd) == unpacked else { throw ArchiveError.damaged }
            }
            guard try integer(blockHeader, cursor: &field, end: headerEnd) == 0x21,
                  try integer(blockHeader, cursor: &field, end: headerEnd) == 1,
                  field < headerEnd else { throw ArchiveError.unsupported }
            let property = blockHeader[field]; field += 1
            // Property 28 is 64 MiB; 29 already requests 96 MiB. This also
            // excludes reserved bits and the special 4 GiB dictionary encoding.
            guard property <= 28 else { throw ArchiveError.limit }
            let dictionary = Int64(2 | (property & 1)) << (Int(property / 2) + 11)
            guard dictionary <= maximumDictionaryBytes else { throw ArchiveError.limit }
            guard blockHeader[field..<headerEnd].allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
            let compressedStart = blockOffset + Int64(headerBytes)
            let compressedEnd = compressedStart + compressed
            try framing(window, start: compressedStart, end: compressedEnd, unpacked: unpacked, chunks: &chunks)
            let padding = Int(padded - unpadded)
            guard try bytes(input, at: compressedEnd, count: padding).allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
            blockOffset += padded
        }
        guard blockOffset == indexOffset, (0...3).contains(index.count - 4 - cursor),
              index[cursor..<(index.count - 4)].allSatisfy({ $0 == 0 }) else { throw ArchiveError.damaged }
        try input.stamp.verify(descriptor: input.descriptor)
    }

    /// Check actual LZMA2 framing, not just Index offsets. Otherwise a forged
    /// unpadded size could conceal an early end marker and another unchecked
    /// block that the decoder reaches before it notices the Index mismatch.
    private static func framing(_ window: Window, start: Int64, end: Int64, unpacked: Int64, chunks: inout Int) throws {
        var position = start, produced: Int64 = 0
        var needsDictionary = true, needsProperties = true, needsState = true
        func take() throws -> UInt8 {
            guard position < end else { throw ArchiveError.damaged }
            let result = try window.byte(at: position); position += 1; return result
        }
        func twoBytes() throws -> Int64 { Int64(try take()) * 256 + Int64(try take()) + 1 }
        while position < end {
            try Task.checkCancellation()
            let control = try take()
            if control == 0 {
                guard position == end, produced == unpacked else { throw ArchiveError.damaged }
                return
            }
            chunks += 1
            guard chunks <= maximumChunks else { throw ArchiveError.limit }
            let length: Int64, output: Int64
            if control == 1 || control >= 0xe0 {
                needsDictionary = false; needsProperties = true; needsState = true
            }
            guard !needsDictionary else { throw ArchiveError.damaged }
            if control < 0x80 {
                guard control == 1 || control == 2 else { throw ArchiveError.damaged }
                length = try twoBytes(); output = length; needsState = true
            } else {
                output = Int64(control & 0x1f) * 65536 + (try twoBytes())
                length = try twoBytes()
                if control >= 0xc0 {
                    let property = Int(try take())
                    guard property < 225, property % 9 + (property / 9) % 5 <= 4 else { throw ArchiveError.damaged }
                    needsProperties = false; needsState = false
                } else {
                    guard !needsProperties, !needsState || control >= 0xa0 else { throw ArchiveError.damaged }
                    needsState = false
                }
            }
            guard length <= end - position, output <= unpacked - produced else { throw ArchiveError.damaged }
            position += length; produced += output
        }
        throw ArchiveError.damaged // A block must end with its explicit LZMA2 marker.
    }

    private static func bytes(_ input: ArchiveInput, at offset: Int64, count: Int) throws -> Data {
        let data = try input.read(offset: offset, count: count)
        guard data.count == count else { throw ArchiveError.damaged }
        return data
    }
    private static func integer(_ data: Data, cursor: inout Int, end: Int) throws -> Int64 {
        var result: UInt64 = 0
        for shift in 0..<9 {
            guard cursor < end else { throw ArchiveError.damaged }
            let byte = data[cursor]; cursor += 1
            result |= UInt64(byte & 0x7f) << (shift * 7)
            if byte & 0x80 == 0 {
                guard shift == 0 || byte != 0 else { throw ArchiveError.damaged }
                return Int64(result)
            }
        }
        throw ArchiveError.damaged
    }
    private static func little32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return ~crc
    }
    private final class Window {
        let input: ArchiveInput
        var offset: Int64 = 0, data = Data()
        init(_ input: ArchiveInput) { self.input = input }
        func byte(at position: Int64) throws -> UInt8 {
            if position < offset || position - offset >= Int64(data.count) {
                offset = position; data = try input.read(offset: position, count: 64 * 1024)
            }
            guard position >= offset, position - offset < Int64(data.count) else { throw ArchiveError.damaged }
            return data[Int(position - offset)]
        }
    }
}

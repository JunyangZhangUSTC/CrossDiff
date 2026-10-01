import Foundation
import Darwin

public enum BinaryFileDetectionError: LocalizedError {
    case notLocalFile
    case notRegularFile

    public var errorDescription: String? {
        switch self {
        case .notLocalFile:
            return L("只能检查本地文件。", "Only local files can be inspected.")
        case .notRegularFile:
            return L("只能检查普通文件，不能读取目录或特殊文件。", "Only regular files can be inspected; directories and special files are not supported.")
        }
    }
}

/// A bounded routing hint, not proof of the encoding of the complete file.
/// Callers retain precedence for directories, image formats and plugin inputs.
public enum BinaryFileDetection {
    public static let maximumSampleBytes = 8 * 1024

    /// Recognizes UTF-8 and BOM-marked UTF-16. Unsupported encodings can be
    /// routed to bytes; printable binary data can still require explicit mode.
    /// At most 8 KiB is read regardless of the file's size or extension.
    public static func isLikelyBinary(url: URL) throws -> Bool {
        guard url.isFileURL else { throw BinaryFileDetectionError.notLocalFile }
        // O_NONBLOCK prevents FIFO open from waiting for a writer before fstat.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw BinaryFileDetectionError.notRegularFile
        }
        var sample = [UInt8](repeating: 0, count: maximumSampleBytes)
        var count = 0
        while count < maximumSampleBytes {
            try Task.checkCancellation()
            let received = sample.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), maximumSampleBytes - count)
            }
            if received == 0 { break }
            if received < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            count += received
        }
        let bytes = sample.prefix(count)
        let isPrefix = count == maximumSampleBytes && info.st_size > Int64(count)
        if bytes.starts(with: [0xff, 0xfe]) {
            return !isTextUTF16(bytes.dropFirst(2), littleEndian: true, allowIncompleteTail: isPrefix)
        }
        if bytes.starts(with: [0xfe, 0xff]) {
            return !isTextUTF16(bytes.dropFirst(2), littleEndian: false, allowIncompleteTail: isPrefix)
        }
        // A complete file ending in half a code point is invalid. Only the
        // bounded prefix of a larger file may legitimately stop mid-character.
        var completeBytes = bytes
        if isPrefix {
            for length in 1...min(3, bytes.count) where isIncompleteUTF8(bytes.suffix(length)) {
                completeBytes = bytes.dropLast(length)
                break
            }
        }
        guard let text = String(bytes: completeBytes, encoding: .utf8) else { return true }
        return !text.unicodeScalars.allSatisfy { isTextScalar($0.value) }
    }

    private static func isIncompleteUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first else { return false }
        let expected: Int
        switch first {
        case 0xc2...0xdf: expected = 2
        case 0xe0...0xef: expected = 3
        case 0xf0...0xf4: expected = 4
        default: return false
        }
        guard bytes.count < expected, bytes.dropFirst().allSatisfy({ (0x80...0xbf).contains($0) }) else { return false }
        if bytes.count > 1 {
            let second = bytes[bytes.startIndex + 1]
            // Reject overlong values, surrogate scalars and values > U+10FFFF,
            // even when the rest of the code point lies outside the sample.
            if first == 0xe0 && second < 0xa0 || first == 0xed && second > 0x9f ||
                first == 0xf0 && second < 0x90 || first == 0xf4 && second > 0x8f { return false }
        }
        return true
    }

    private static func isTextUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool, allowIncompleteTail: Bool) -> Bool {
        guard bytes.count.isMultiple(of: 2) else { return false }
        func unit(at index: Int) -> UInt16 {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            return littleEndian ? first | (second << 8) : (first << 8) | second
        }
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let value = unit(at: index)
            index += 2
            if (0xd800...0xdbff).contains(value) {
                if index == bytes.endIndex { return allowIncompleteTail }
                guard (0xdc00...0xdfff).contains(unit(at: index)) else { return false }
                index += 2
            } else if (0xdc00...0xdfff).contains(value) || !isTextScalar(UInt32(value)) {
                return false
            }
        }
        return true
    }

    private static func isTextScalar(_ value: UInt32) -> Bool {
        (value >= 0x20 && value != 0x7f) || (9...13).contains(value)
    }
}

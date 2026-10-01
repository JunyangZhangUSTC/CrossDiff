import Foundation
import Darwin

/// libarchive 3.7.4 does not validate the gzip trailer. zlib's gzip reader
/// checks every member's CRC/ISIZE, including a truncated final member.
/// This bounded validation pass completes before the TAR catalog is read.
enum ArchiveGZIP {
    static func validate(_ input: ArchiveInput) throws {
        let library = try ArchiveLibrary(path: "/usr/lib/libz.1.dylib")
        defer { withExtendedLifetime(library) {} }
        let openGZIP = try library.function("gzdopen", (@convention(c) (Int32, UnsafePointer<CChar>?) -> OpaquePointer?).self)
        let readGZIP = try library.function("gzread", (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UInt32) -> Int32).self)
        let closeGZIP = try library.function("gzclose", (@convention(c) (OpaquePointer?) -> Int32).self)
        let errorGZIP = try library.function("gzerror", (@convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> UnsafePointer<CChar>?).self)
        let directGZIP = try library.function("gzdirect", (@convention(c) (OpaquePointer?) -> Int32).self)
        guard lseek(input.descriptor, 0, SEEK_SET) == 0 else { throw ArchiveError.damaged }
        let fd = dup(input.descriptor)
        guard fd >= 0 else { throw ArchiveError.unavailable }
        guard let stream = openGZIP(fd, "rb") else { close(fd); throw ArchiveError.unavailable }
        var closed = false
        defer { if !closed { _ = closeGZIP(stream) } }
        guard directGZIP(stream) == 0 else { throw ArchiveError.damaged }
        var bytes = Data(count: 64 * 1024), total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let amount = bytes.withUnsafeMutableBytes { readGZIP(stream, $0.baseAddress, UInt32($0.count)) }
            var code: Int32 = 0; _ = errorGZIP(stream, &code)
            guard amount >= 0, code == 0 else { throw ArchiveError.damaged }
            total += Int64(amount)
            guard total <= ArchiveCatalog.maximumExpandedBytes + 32 * 1024 * 1024 else { throw ArchiveError.limit }
            try input.stamp.verify(descriptor: input.descriptor)
            if amount == 0 { break }
        }
        let status = closeGZIP(stream); closed = true
        guard status == 0 else { throw ArchiveError.damaged }
        try input.stamp.verify(descriptor: input.descriptor)
    }
}

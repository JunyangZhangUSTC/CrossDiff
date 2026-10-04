import Foundation
import Darwin

/// C ABI declarations are checked against the SDK's libarchive man pages and
/// exported symbol stub. No extraction/writer/program-filter APIs are bound.
final class ArchiveLibrary {
    let handle: UnsafeMutableRawPointer
    init(path: String = "/usr/lib/libarchive.2.dylib") throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw ArchiveError.unavailable }
        self.handle = handle
    }
    deinit { dlclose(handle) }
    func function<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let symbol = dlsym(handle, name) else { throw ArchiveError.unavailable }
        return unsafeBitCast(symbol, to: type)
    }
}

final class ArchiveStream {
    typealias ArchiveCall = @convention(c) (OpaquePointer?) -> Int32
    let input: ArchiveInput
    private let library: ArchiveLibrary
    private let archive: OpaquePointer
    private let free: ArchiveCall
    private let nextHeader: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private let dataRead: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private let entryPathUTF8: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private let entryPath: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private let entryType: @convention(c) (OpaquePointer?) -> mode_t
    private let entrySize: @convention(c) (OpaquePointer?) -> Int64
    private let entrySizeSet: ArchiveCall
    private let entryHardLink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private let entryEncrypted: ArchiveCall
    private var closed = false

    convenience init(input: ArchiveInput, zip: Bool) throws {
        try self.init(input: input, format: zip ? "zip_seekable" : "raw")
    }
    init(input: ArchiveInput, format: String) throws {
        self.input = input
        let library = try ArchiveLibrary(); self.library = library
        let free = try library.function("archive_read_free", ArchiveCall.self); self.free = free
        let make = try library.function("archive_read_new", (@convention(c) () -> OpaquePointer?).self)
        guard let handle = make() else { throw ArchiveError.unavailable }
        self.archive = handle
        var initialized = false
        defer { if !initialized { _ = free(handle) } }
        nextHeader = try library.function("archive_read_next_header", (@convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32).self)
        dataRead = try library.function("archive_read_data", (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int).self)
        entryPathUTF8 = try library.function("archive_entry_pathname_utf8", (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        entryPath = try library.function("archive_entry_pathname", (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        entryType = try library.function("archive_entry_filetype", (@convention(c) (OpaquePointer?) -> mode_t).self)
        entrySize = try library.function("archive_entry_size", (@convention(c) (OpaquePointer?) -> Int64).self)
        entrySizeSet = try library.function("archive_entry_size_is_set", ArchiveCall.self)
        entryHardLink = try library.function("archive_entry_hardlink", (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        entryEncrypted = try library.function("archive_entry_is_encrypted", ArchiveCall.self)
        initialized = true
        let signature = try input.read(offset: 0, count: 6)
        let filter: (code: Int32, symbol: String)
        if format == "raw" && signature.starts(with: [0x1f, 0x8b]) { filter = (1, "gzip") }
        else if format == "raw" && signature.starts(with: [0x42, 0x5a, 0x68]) { filter = (2, "bzip2") }
        else if format == "raw" && signature == Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) { filter = (6, "xz") }
        else { filter = (0, "none") }
        for symbol in ["archive_read_support_filter_" + filter.symbol, "archive_read_support_format_" + format] {
            // WARN can mean an external program fallback. Only built-in OK is accepted.
            guard try library.function(symbol, ArchiveCall.self)(handle) == 0 else { throw ArchiveError.unsupported }
        }
        // Disable recursive auto-bidding, including for NONE. Otherwise an outer
        // gzip/bzip2 layer could expose an XZ decoder that bypasses preflight.
        let append = try library.function("archive_read_append_filter", (@convention(c) (OpaquePointer?, Int32) -> Int32).self)
        guard append(handle, filter.code) == 0 else { throw ArchiveError.unsupported }
        guard lseek(input.descriptor, 0, SEEK_SET) == 0 else { throw ArchiveError.unreadable(input.stamp.url.lastPathComponent) }
        let open = try library.function("archive_read_open_fd", (@convention(c) (OpaquePointer?, Int32, Int) -> Int32).self)
        guard open(handle, input.descriptor, 64 * 1024) == 0 else { throw ArchiveError.damaged }
        initialized = true
    }
    deinit { if !closed { _ = free(archive) } }
    func next() throws -> OpaquePointer? {
        try Task.checkCancellation(); try input.stamp.verify(descriptor: input.descriptor)
        var entry: OpaquePointer?
        let status = nextHeader(archive, &entry)
        if status == 1 { return nil }
        guard status == 0, let entry else { throw ArchiveError.damaged }
        guard entryEncrypted(entry) == 0 else { throw ArchiveError.encrypted }
        return entry
    }
    func description(_ entry: OpaquePointer) throws -> (path: String, kind: ArchiveEntryKind, size: Int64?) {
        guard let path = entryPathUTF8(entry) ?? entryPath(entry), strnlen(path, 4097) <= 4096,
              let string = String(validatingUTF8: path) else { throw ArchiveError.invalidPath }
        let type = entryType(entry)
        let kind: ArchiveEntryKind
        if entryHardLink(entry) != nil { kind = .hardLink }
        else if type == mode_t(S_IFREG) { kind = .file }
        else if type == mode_t(S_IFDIR) { kind = .directory }
        else if type == mode_t(S_IFLNK) { kind = .symbolicLink }
        else { kind = .other }
        let size = entrySizeSet(entry) == 0 ? nil : entrySize(entry)
        guard size == nil || size! >= 0 else { throw ArchiveError.damaged }
        return (string, kind, size)
    }
    func symbolicLinkBytes(_ entry: OpaquePointer) throws -> Data {
        let target = try library.function("archive_entry_symlink", (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        guard let pointer = target(entry) else { throw ArchiveError.damaged }
        let count = strnlen(pointer, 4097)
        guard count <= 4096 else { throw ArchiveError.limit }
        return Data(bytes: pointer, count: count)
    }
    func read(maximum: Int = 64 * 1024) throws -> Data {
        try Task.checkCancellation()
        guard maximum > 0, maximum <= 64 * 1024 else { throw ArchiveError.limit }
        var data = Data(count: maximum)
        let amount = data.withUnsafeMutableBytes { dataRead(archive, $0.baseAddress, maximum) }
        guard amount >= 0, amount <= maximum else { throw ArchiveError.damaged }
        data.count = amount
        try input.stamp.verify(descriptor: input.descriptor)
        return data
    }
    func verifySourceConsumed() throws {
        let consumed = try library.function("archive_filter_bytes", (@convention(c) (OpaquePointer?, Int32) -> Int64).self)
        // -1 denotes the outermost/source filter. Read-ahead bytes that were
        // never consumed are excluded, so silently ignored tails are rejected.
        guard consumed(archive, -1) == input.size else { throw ArchiveError.damaged }
        try input.stamp.verify(descriptor: input.descriptor)
    }
    func finish() throws {
        guard !closed else { return }
        let status = free(archive); closed = true
        guard status == 0 else { throw ArchiveError.damaged }
        try input.stamp.verify(descriptor: input.descriptor)
    }
}

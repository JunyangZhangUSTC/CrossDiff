import Foundation
import Darwin

/// Decoder containment, not a security sandbox: deadline/CPU/output caps and a
/// sampled RSS watchdog complement the format preflight. A native decoder crash
/// never yields a partial snapshot or takes down the application process.
enum ArchiveReaderProcess {
    static let maximumReplyBytes = 16 * 1024 * 1024
    static let maximumResidentBytes: UInt64 = 512 * 1024 * 1024
    static let timeout: TimeInterval = 60

    static func read(_ input: ArchiveInput, executable: URL?) throws -> ArchiveSnapshot {
        try Task.checkCancellation()
        guard let executable, executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ArchiveError.readerUnavailable
        }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--read", input.stamp.url.path]
        let fd = dup(input.descriptor)
        guard fd >= 0 else { throw ArchiveError.readerFailed }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        process.standardInput = source
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A bundled helper needs no caller-provided loader injection or settings.
        process.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        do { try process.run() } catch { throw ArchiveError.readerUnavailable }
        try? output.fileHandleForWriting.close()
        let readFD = output.fileHandleForReading.fileDescriptor
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else {
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw ArchiveError.readerFailed
        }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func checkLimits() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ArchiveError.timeout }
            try input.stamp.verify(descriptor: input.descriptor)
            var info = proc_taskinfo()
            if process.isRunning {
                let count = proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                guard count == MemoryLayout<proc_taskinfo>.size || !process.isRunning else { throw ArchiveError.readerFailed }
                guard info.pti_resident_size <= maximumResidentBytes else { throw ArchiveError.limit }
            }
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024), ended = false
        while !ended {
            try checkLimits()
            let amount = Darwin.read(readFD, &buffer, buffer.count)
            if amount > 0 {
                guard amount <= maximumReplyBytes - bytes.count else { throw ArchiveError.limit }
                bytes.append(contentsOf: buffer.prefix(amount))
            } else if amount == 0 { ended = true }
            else if errno != EAGAIN && errno != EINTR { throw ArchiveError.readerFailed }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        // EOF alone is insufficient: a faulty helper may close stdout and hang.
        while process.isRunning {
            try checkLimits()
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let reply = try? JSONDecoder().decode(ArchiveReaderReply.self, from: bytes) else { throw ArchiveError.readerFailed }
        if let error = reply.error { throw error }
        guard let entries = reply.entries, let total = reply.totalExpandedBytes,
              entries.count <= ArchiveCatalog.maximumEntries, total >= 0, total <= ArchiveCatalog.maximumExpandedBytes else { throw ArchiveError.readerFailed }
        // Revalidate even trusted helper output before publishing it to plugins.
        let builder = ArchiveBuilder(); builder.stamps.append(input.stamp)
        for entry in entries {
            guard let size = entry.size, size >= 0, size <= ArchiveCatalog.maximumFileBytes else { throw ArchiveError.readerFailed }
            if entry.kind == .file {
                guard entry.issue == nil, let hash = entry.sha256, hash.utf8.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ArchiveError.readerFailed }
            } else {
                guard entry.sha256 == nil,
                      (entry.kind == .directory && size == 0 && entry.issue == nil) ||
                        (entry.kind == .symbolicLink && entry.issue == .symbolicLink) ||
                        (entry.kind == .hardLink && entry.issue == .hardLink) ||
                        (entry.kind == .other && entry.issue == .specialFile) else { throw ArchiveError.readerFailed }
            }
            try builder.account(size, fileBytes: size)
            try builder.add(rawPath: entry.path, kind: entry.kind, size: size, digest: entry.sha256, issue: entry.issue)
        }
        guard builder.totalBytes == total else { throw ArchiveError.readerFailed }
        return try builder.finish(url: input.stamp.url, kind: .archive)
    }
}

extension ArchiveCatalog {
    /// Entrypoint for the bundled reader executable; not called by the UI process.
    public static func runNativeReader() {
        var cpu = rlimit(rlim_cur: 60, rlim_max: 60), core = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CPU, &cpu); _ = setrlimit(RLIMIT_CORE, &core)
        let reply: ArchiveReaderReply
        var format: ArchiveNativeFormat?
        do {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--read" else { throw ArchiveError.readerFailed }
            let input = try ArchiveInput(url: URL(fileURLWithPath: CommandLine.arguments[2]), inheritedDescriptor: STDIN_FILENO)
            format = ArchiveNativeFormat.identify(try input.read(offset: 0, count: 8))
            let snapshot = try ArchiveNativeReader.read(input)
            reply = ArchiveReaderReply(entries: snapshot.entries, totalExpandedBytes: snapshot.totalExpandedBytes, error: nil)
        } catch {
            var issue = (error as? ArchiveError) ?? .readerFailed
            if case .unsupported = issue, let format {
                issue = format == .sevenZip ? .unsupported7z : .unsupportedRAR
            }
            reply = ArchiveReaderReply(entries: nil, totalExpandedBytes: nil, error: issue)
        }
        do {
            let bytes = try JSONEncoder().encode(reply)
            guard bytes.count <= ArchiveReaderProcess.maximumReplyBytes else { throw ArchiveError.limit }
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch {
            let fallback = ArchiveReaderReply(entries: nil, totalExpandedBytes: nil, error: .limit)
            if let bytes = try? JSONEncoder().encode(fallback) { try? FileHandle.standardOutput.write(contentsOf: bytes) }
        }
    }
}

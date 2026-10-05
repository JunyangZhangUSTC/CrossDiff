import Foundation
import Darwin

/// Executes a fixed system Git binary without a shell, and drains both output streams
/// with bounded reads. Catalogs stream records without a total byte/deadline cap;
/// previews and network operations retain explicit limits. Never call on the UI thread.
enum GitProcess {
    static let maximumOutput = 16 * 1024 * 1024
    static let maximumInput = 16 * 1024
    static var systemGitAvailable: Bool {
        let fm = FileManager.default
        let selected = URL(fileURLWithPath: "/var/db/xcode_select_link").resolvingSymlinksInPath()
        if selected.path != "/var/db/xcode_select_link" {
            return fm.isExecutableFile(atPath: selected.appendingPathComponent("usr/bin/git").path)
        }
        return ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"].contains { fm.isExecutableFile(atPath: $0) }
    }
    static let sshCommand = "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ControlMaster=no -o ControlPath=none -o ProxyCommand=none -o ProxyJump=none -o PermitLocalCommand=no -o ConnectTimeout=15"

    static func run(at directory: URL?, arguments: [String], network: Bool = false, input: Data? = nil,
                    maximumBytes: Int = maximumOutput, timeout: TimeInterval = 45,
                    isCancelled: () -> Bool = { false }, checkResources: () throws -> Void = {}) throws -> Data {
        var output = Data()
        try execute(at: directory, arguments: arguments, network: network, input: input, timeout: timeout,
                    isCancelled: isCancelled, checkResources: checkResources) { chunk in
            guard chunk.count <= maximumBytes - output.count else { throw GitError.tooLarge }
            output.append(chunk)
        }
        return output
    }

    /// Delimits only one record at a time; output size is proportional to the caller's
    /// resulting catalog, not a second complete stdout copy. EOF must end a record.
    static func streamRecords(at directory: URL?, arguments: [String], separator: UInt8 = 0,
                              maximumRecordBytes: Int = 1024 * 1024, isCancelled: () -> Bool = { false },
                              onRecord: (Data) throws -> Void) throws {
        var pending = Data()
        try execute(at: directory, arguments: arguments, timeout: nil, isCancelled: isCancelled) { chunk in
            var start = chunk.startIndex
            while start < chunk.endIndex {
                if isCancelled() { throw GitError.cancelled }
                let end = chunk[start...].firstIndex(of: separator) ?? chunk.endIndex
                guard end - start <= maximumRecordBytes - pending.count else { throw GitError.invalidOutput }
                pending.append(contentsOf: chunk[start..<end])
                if end < chunk.endIndex {
                    let record = pending
                    pending = Data()
                    try onRecord(record)
                    start = end + 1
                } else { start = end }
            }
        }
        guard pending.isEmpty else { throw GitError.invalidOutput }
    }

    private static func execute(at directory: URL?, arguments: [String], network: Bool = false, input: Data? = nil,
                                timeout: TimeInterval?, isCancelled: () -> Bool,
                                checkResources: () throws -> Void = {}, onBytes: (Data) throws -> Void) throws {
        guard !isCancelled() else { throw GitError.cancelled }
        guard (input?.count ?? 0) <= maximumInput else { throw GitError.tooLarge }
        guard systemGitAvailable, FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw GitError.unavailable }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        let stdin = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "--no-optional-locks", "--literal-pathspecs",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
            "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-c", "credential.helper=",
            "-c", "credential.interactive=false", "-c", "core.askPass=/usr/bin/false",
            "-c", "core.sshCommand=" + sshCommand, "-c", "ssh.variant=ssh",
            "-c", "protocol.allow=never", "-c", "protocol.https.allow=" + (network ? "always" : "never"),
            "-c", "protocol.ssh.allow=" + (network ? "always" : "never"),
            "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never",
            "-c", "http.followRedirects=false", "-c", "http.sslVerify=true",
            "-c", "core.pager=cat", "-c", "diff.external=", "-c", "diff.ignoreSubmodules=none",
            "-c", "core.attributesFile=/dev/null", "-c", "color.ui=false"] + arguments
        let inherited = ProcessInfo.processInfo.environment
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
                   "SSH_ASKPASS_REQUIRE": "never", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1",
                   "GIT_NO_LAZY_FETCH": "1", "GIT_ATTR_NOSYSTEM": "1", "GIT_PAGER": "cat",
                   "GIT_SSH_COMMAND": sshCommand, "GIT_SSH_VARIANT": "ssh",
                   "GIT_ALLOW_PROTOCOL": network ? "https:ssh" : ""]
        // Preserve the user's identity/agent location, never repoint HOME or load shell startup files.
        for key in ["HOME", "TMPDIR", "SSH_AUTH_SOCK"] { if let value = inherited[key] { env[key] = value } }
        process.environment = env
        if let stdin { process.standardInput = stdin }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw GitError.unavailable }
        try? stdin?.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let outFD = stdout.fileHandleForReading.fileDescriptor, errFD = stderr.fileHandleForReading.fileDescriptor
        let inFD = stdin?.fileHandleForWriting.fileDescriptor
        defer {
            try? stdin?.fileHandleForWriting.close()
            if process.isRunning {
                // Foundation normally gives spawned processes a separate process group. Only
                // signal a group if verified; never signal the application's process group.
                let pid = process.processIdentifier
                if getpgid(pid) == pid && pid != getpgrp() { _ = kill(-pid, SIGKILL) }
                else { _ = kill(pid, SIGKILL) }
            }
            process.waitUntilExit()
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) == 0, fcntl(errFD, F_SETFL, O_NONBLOCK) == 0 else { throw GitError.commandFailed }
        if let inFD {
            let flags = fcntl(inFD, F_GETFL)
            guard flags >= 0, fcntl(inFD, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(inFD, F_SETNOSIGPIPE, 1) == 0 else { throw GitError.commandFailed }
        }
        var inputOffset = 0, inputClosed = stdin == nil, inputRejected = false
        var errorBytes = 0, outEnded = false, errEnded = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var nextResourceCheck = ProcessInfo.processInfo.systemUptime
        while !outEnded || !errEnded || process.isRunning {
            if isCancelled() { throw GitError.cancelled }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw GitError.timeout }
            if ProcessInfo.processInfo.systemUptime >= nextResourceCheck {
                try checkResources()
                nextResourceCheck = ProcessInfo.processInfo.systemUptime + 0.25
            }
            var readSomething = false
            // A bounded batch may still exceed pipe capacity. Interleave nonblocking
            // input with both output drains so cat-file cannot deadlock under pressure.
            if !inputClosed, let input, let inFD {
                if inputOffset < input.count {
                    let n = input.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: inputOffset),
                                     min(64 * 1024, input.count - inputOffset))
                    }
                    if n > 0 { inputOffset += n; readSomething = true }
                    else if n < 0 {
                        if errno == EPIPE { inputRejected = true }
                        else if errno != EAGAIN && errno != EINTR { throw GitError.commandFailed }
                    }
                }
                if inputOffset == input.count || inputRejected {
                    try? stdin?.fileHandleForWriting.close()
                    inputClosed = true
                }
            }
            if !outEnded {
                let n = Darwin.read(outFD, &buffer, buffer.count)
                if n > 0 {
                    try onBytes(Data(buffer.prefix(n))); readSomething = true
                } else if n == 0 { outEnded = true }
                else if errno != EAGAIN && errno != EINTR { throw GitError.commandFailed }
            }
            if !errEnded {
                let n = Darwin.read(errFD, &buffer, buffer.count)
                if n > 0 {
                    errorBytes += n
                    guard errorBytes <= 1024 * 1024 else { throw GitError.tooLarge }
                    readSomething = true
                } else if n == 0 { errEnded = true }
                else if errno != EAGAIN && errno != EINTR { throw GitError.commandFailed }
            }
            if !readSomething { Thread.sleep(forTimeInterval: 0.008) }
        }
        process.waitUntilExit()
        guard !inputRejected, inputOffset == (input?.count ?? 0),
              process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw network ? GitError.networkFailed : GitError.commandFailed
        }
    }
}

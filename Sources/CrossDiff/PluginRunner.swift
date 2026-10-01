import Foundation
import CrossDiffCore
import Darwin
import Security

struct PluginRunLimits: Sendable {
    var timeout: TimeInterval = 15
    var maximumInputBytes: Int = 32 * 1024 * 1024
    var maximumOutputBytes: Int = 8 * 1024 * 1024
    var maximumStderrBytes: Int = 16 * 1024
    var maximumResidentBytes: UInt64 = 512 * 1024 * 1024
    static let `default` = PluginRunLimits()
}

/// A JSON-only child runtime. Restricted JavaScript is not an operating-system sandbox.
enum PluginRunner {
    static func run(package: PluginPackage, request: PluginComparisonRequest, helperURL: URL,
                    nativeExecutableURL: URL? = nil, approvedNativeDigest: String? = nil,
                    limits: PluginRunLimits = .default) async throws -> PluginComparisonResult {
        let cancellation = PluginRunCancellation()
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await Task.detached(priority: .userInitiated) {
            try cancellation.check()
            try package.validate()
            try request.validate(for: package.manifest)
            guard limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 60,
                  (1...(32 * 1024 * 1024)).contains(limits.maximumInputBytes),
                  (1...(8 * 1024 * 1024)).contains(limits.maximumOutputBytes),
                  (1...(64 * 1024)).contains(limits.maximumStderrBytes), limits.maximumResidentBytes > 0 else {
                throw PluginRunError.invalidLimits
            }
            struct Envelope: Encodable {
                let script: String
                let request: PluginComparisonRequest
                let cpuTimeLimitSeconds: Int
            }
            let input: Data
            let executable: URL
            switch package.manifest.runtime {
            case .restrictedJavaScript:
                guard let script = package.script else { throw PluginValidationError.invalidPayload }
                input = try JSONEncoder().encode(Envelope(script: script, request: request,
                    cpuTimeLimitSeconds: min(30, max(1, Int(ceil(limits.timeout))))))
                executable = helperURL
            case .trustedExecutable:
                guard approvedNativeDigest == package.sha256, let nativeExecutableURL else {
                    throw PluginValidationError.nativeTrustRequired
                }
                try verifyNativeExecutable(at: nativeExecutableURL, expectedDigest: package.sha256)
                input = try JSONEncoder().encode(request)
                executable = nativeExecutableURL
            }
            guard input.count <= limits.maximumInputBytes else { throw PluginRunError.inputLimit }
            let output = try execute(executable, input: input, limits: limits, cancellation: cancellation)
            let result = try JSONDecoder().decode(PluginComparisonResult.self, from: output)
            try result.validate(for: request, manifest: package.manifest)
            try cancellation.check()
            return result
          }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Code integrity is separate from publisher trust. In particular, an ad-hoc
    /// signature may be valid without identifying an Apple-verified developer.
    static func verifyNativeExecutable(at url: URL, expectedDigest: String) throws {
        guard url.isFileURL else { throw PluginRunError.unsafeExecutable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw PluginRunError.unsafeExecutable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size >= 0,
              before.st_size <= PluginPackage.maximumExecutableBytes else { throw PluginRunError.unsafeExecutable }
        var payload = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PluginRunError.unsafeExecutable
            }
            guard count <= PluginPackage.maximumExecutableBytes - payload.count else { throw PluginRunError.unsafeExecutable }
            payload.append(contentsOf: buffer.prefix(count))
        }
        guard PluginPackage.digest(of: payload) == expectedDigest else { throw PluginValidationError.digestMismatch }
        // Never clear quarantine or launch quarantined code through a lower-level bypass.
        // The preview conservatively declines this case; it does not implement Gatekeeper approval UI.
        let quarantineLength = fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0)
        guard quarantineLength < 0, errno == ENOATTR else { throw PluginRunError.quarantinedExecutable }
        var staticCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode, SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            throw PluginRunError.invalidCodeSignature
        }
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &current) == 0,
              before.st_dev == current.st_dev, before.st_ino == current.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PluginValidationError.digestMismatch
        }
    }

    private static func execute(_ executable: URL, input: Data, limits: PluginRunLimits,
                                cancellation: PluginRunCancellation) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        // Do not leak application secrets through the inherited process environment.
        var environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        for key in ["TMPDIR", "CFFIXED_USER_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                       stdout.fileHandleForReading, stdout.fileHandleForWriting,
                       stderr.fileHandleForReading, stderr.fileHandleForWriting]
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            for handle in handles { try? handle.close() }
        }
        try cancellation.check()
        try process.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        for descriptor in [inputFD, stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw PluginRunError.executionFailed }
        }
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw PluginRunError.executionFailed }
        var written = 0, inputClosed = false
        var output = Data(), errorOutput = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + limits.timeout
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PluginRunError.timedOut }
            // proc_pidinfo can be denied by system policy. CPU and wall-time limits remain
            // active then; this monitor is a measured resource budget, not memory isolation.
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize) == taskInfoSize,
               taskInfo.pti_resident_size > limits.maximumResidentBytes {
                throw PluginRunError.memoryLimit
            }
            if !inputClosed {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: written), min(64 * 1024, input.count - written))
                }
                if count > 0 { written += count }
                else if count < 0, errno != EAGAIN, errno != EINTR, errno != EPIPE { throw PluginRunError.executionFailed }
                if written == input.count || (count < 0 && errno == EPIPE) {
                    try? stdin.fileHandleForWriting.close()
                    inputClosed = true
                }
            }
            try drain(stdout.fileHandleForReading.fileDescriptor, into: &output, maximum: limits.maximumOutputBytes)
            try drain(stderr.fileHandleForReading.fileDescriptor, into: &errorOutput, maximum: limits.maximumStderrBytes)
            if !process.isRunning {
                process.waitUntilExit()
                try drain(stdout.fileHandleForReading.fileDescriptor, into: &output, maximum: limits.maximumOutputBytes)
                try drain(stderr.fileHandleForReading.fileDescriptor, into: &errorOutput, maximum: limits.maximumStderrBytes)
                guard process.terminationStatus == 0 else { throw PluginRunError.executionFailed }
                return output
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func drain(_ descriptor: Int32, into data: inout Data, maximum: Int) throws {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                throw PluginRunError.executionFailed
            }
            guard count <= maximum - data.count else { throw PluginRunError.outputLimit }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}

private final class PluginRunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum PluginRunError: Error, LocalizedError {
    case executionFailed
    case timedOut
    case inputLimit
    case outputLimit
    case invalidLimits
    case memoryLimit
    case unsafeExecutable
    case invalidCodeSignature
    case quarantinedExecutable

    var errorDescription: String? {
        switch self {
        case .executionFailed:
            return L("插件执行失败，未发布比较结果。", "The plugin failed. No comparison result was published.")
        case .timedOut:
            return L("插件运行超时，已停止。", "The plugin exceeded its time limit and was stopped.")
        case .inputLimit:
            return L("插件输入超过运行时大小限制。", "The plugin input exceeds the runtime size limit.")
        case .outputLimit:
            return L("插件输出超过运行时大小限制，已停止。", "The plugin output exceeded the runtime size limit and was stopped.")
        case .invalidLimits:
            return L("插件运行限制无效。", "The plugin execution limits are invalid.")
        case .memoryLimit:
            return L("插件使用内存超出限制，已停止。", "The plugin exceeded its memory limit and was stopped.")
        case .unsafeExecutable:
            return L("原生插件程序路径无效或不安全。", "The native plugin executable path is invalid or unsafe.")
        case .invalidCodeSignature:
            return L("原生插件代码签名无效，已拒绝执行。", "The native plugin has an invalid code signature and was not executed.")
        case .quarantinedExecutable:
            return L("原生插件带有系统隔离标记，此预览版不会绕过系统批准流程。", "The native plugin is quarantined. This preview does not bypass the system approval process.")
        }
    }
}

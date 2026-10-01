import Foundation
import CrossDiffCore
import Darwin

struct AudioMatchingEvidence: Sendable {
    let correspondences: [AudioCorrespondence]
    /// Resource/result limits or a source too short to analyse; false is not a coverage guarantee.
    let partial: Bool
    let engine: String
}

enum AudioMatchingError: LocalizedError {
    case unavailable, invalidInput, failed, timeout, invalidOutput
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("音频匹配组件不可用，请重新构建完整应用。", "The audio matching component is unavailable. Rebuild the application.")
        case .invalidInput: return L("自动匹配需要两小时以内的 16 kHz 单声道 PCM。", "Automatic matching requires 16 kHz mono PCM no longer than two hours.")
        case .failed: return L("音频匹配未完成，请尝试较短的音频或手动选择区域。", "Audio matching did not complete. Try shorter audio or select regions manually.")
        case .timeout: return L("音频匹配超时，请尝试较短的音频。", "Audio matching timed out. Try shorter audio.")
        case .invalidOutput: return L("音频匹配返回了无效结果。", "Audio matching returned an invalid result.")
        }
    }
}

/// Executes a bundled native helper; PCM never enters the JSON plugin protocol.
/// The caller supplies private Apple-decoded files and a private cache directory.
enum AudioMatchingEngine {
    static func compare(leftPCMURL: URL, rightPCMURL: URL, sampleRate: Double = 16000,
                        cacheDirectory: URL) async throws -> AudioMatchingEvidence {
        guard sampleRate == 16000, leftPCMURL.isFileURL, rightPCMURL.isFileURL, cacheDirectory.isFileURL else {
            throw AudioMatchingError.invalidInput
        }
        let leftDuration = try duration(leftPCMURL), rightDuration = try duration(rightPCMURL)
        let environment = ProcessInfo.processInfo.environment
        let executable = environment["CROSSDIFF_AUDIO_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CrossDiffAudioMatcher")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AudioMatchingError.unavailable }
        let control = AudioMatcherProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try control.checkCancellation()
                let manager = FileManager.default
                try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let job = cacheDirectory.appendingPathComponent("match-" + UUID().uuidString, isDirectory: true)
                try manager.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? manager.removeItem(at: job) }
                let outputURL = job.appendingPathComponent("result.json")
                guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AudioMatchingError.failed }
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                let process = Process()
                process.executableURL = executable
                process.arguments = [leftPCMURL.path, rightPCMURL.path, job.path]
                process.currentDirectoryURL = job
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": job.path, "LANG": "C"]
                try control.start(process)
                let deadline = Date().addingTimeInterval(120)
                while process.isRunning {
                    try control.checkCancellation()
                    if Date() >= deadline {
                        control.cancel(); process.waitUntilExit(); throw AudioMatchingError.timeout
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                try control.checkCancellation()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw AudioMatchingError.failed }
                try output.synchronize()
                let values = try outputURL.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, (1...262144).contains(size) else { throw AudioMatchingError.invalidOutput }
                let wire: MatcherOutput
                do { wire = try JSONDecoder().decode(MatcherOutput.self, from: Data(contentsOf: outputURL)) }
                catch { throw AudioMatchingError.invalidOutput }
                guard wire.engine == "olaf", wire.matches.count <= 512 else { throw AudioMatchingError.invalidOutput }
                let matches = try wire.matches.enumerated().map { index, pair in
                    let left = AudioRegion(start: pair.leftStart, end: pair.leftEnd)
                    let right = AudioRegion(start: pair.rightStart, end: pair.rightEnd)
                    let result = AudioCorrespondence(id: "olaf-\(index)", left: left, right: right,
                        rateRatio: right.duration / left.duration, score: pair.score, method: "olaf")
                    guard result.validated(leftDuration: leftDuration, rightDuration: rightDuration) else { throw AudioMatchingError.invalidOutput }
                    return result
                }
                try control.checkCancellation()
                return AudioMatchingEvidence(correspondences: matches, partial: wire.partial, engine: "olaf")
            }.value
        }, onCancel: { control.cancel() })
    }

    private static func duration(_ url: URL) throws -> Double {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
              bytes > 0, bytes % 4 == 0, bytes <= 7200 * 16000 * 4 else { throw AudioMatchingError.invalidInput }
        return Double(bytes) / 64000
    }

    private struct MatcherOutput: Decodable { let engine: String; let partial: Bool; let matches: [Match] }
    private struct Match: Decodable { let leftStart, leftEnd, rightStart, rightEnd, score: Double }
}

private final class AudioMatcherProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func start(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = value
        try value.run()
    }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; let child = process; lock.unlock()
        if value { child?.waitUntilExit(); throw CancellationError() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}

import Foundation
import Darwin

@main enum AudioCacheChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static let manager = FileManager.default
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func main() throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--hold" {
            let job = try AudioCacheStore.createJob(in: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
            try Data("temporary PCM".utf8).write(to: job.directory.appendingPathComponent("left.f32"))
            FileHandle.standardOutput.write(Data((job.directory.path + "\n").utf8))
            _ = try FileHandle.standardInput.read(upToCount: 1)
            AudioCacheStore.removeJob(job)
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("AudioCache", isDirectory: true)
        try check(try AudioCacheStore.clearInactive(in: cache) == 0, "Missing cache needs no directory creation")
        try check(!manager.fileExists(atPath: cache.path), "Clearing nonexistent cache leaves it nonexistent")
        let first = try AudioCacheStore.createJob(in: cache), second = try AudioCacheStore.createJob(in: cache)
        try Data("a".utf8).write(to: first.directory.appendingPathComponent("left.f32"))
        try check(try AudioCacheStore.clearInactive(in: cache) == 0, "Two active leases in the same process are preserved")
        try check(manager.fileExists(atPath: first.directory.path) && manager.fileExists(atPath: second.directory.path), "Other tabs retain their working files")
        AudioCacheStore.removeJob(first)
        try check(!manager.fileExists(atPath: first.directory.path), "Explicit completion deletes its own job")
        AudioCacheStore.removeJob(first)
        try check(manager.fileExists(atPath: second.directory.path), "Completing twice cannot delete another job")
        var dropped: AudioCacheJob? = try AudioCacheStore.createJob(in: cache)
        let droppedURL = dropped!.directory; dropped = nil
        try check(!manager.fileExists(atPath: droppedURL.path), "A released lease cleans up its completed job")

        let unmarked = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: unmarked, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: unmarked.appendingPathComponent("source.wav"))
        let unknown = cache.appendingPathComponent("personal-notes.txt")
        try Data("keep".utf8).write(to: unknown)
        let malformed = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: malformed, withIntermediateDirectories: false)
        try Data("wrong marker".utf8).write(to: malformed.appendingPathComponent(AudioCacheStore.markerName))
        try check(try AudioCacheStore.clearInactive(in: cache) == 0, "Unmarked and malformed jobs are not considered owned cache")
        try check(manager.fileExists(atPath: unmarked.path) && manager.fileExists(atPath: malformed.path) && manager.fileExists(atPath: unknown.path), "Unknown files and directories remain untouched")

        let outside = root.appendingPathComponent("OutsideCache", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("original.wav")
        let sentinelBytes = Data("original audio must survive".utf8)
        try sentinelBytes.write(to: sentinel)
        let linkedJob = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createSymbolicLink(at: linkedJob, withDestinationURL: outside)
        try check(try AudioCacheStore.clearInactive(in: cache) == 0 && manager.fileExists(atPath: linkedJob.path), "A UUID-shaped directory symlink is skipped")
        let nested = try AudioCacheStore.createJob(in: cache)
        let realDirectory = nested.directory.appendingPathComponent("match-data", isDirectory: true)
        try manager.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        try Data("index".utf8).write(to: realDirectory.appendingPathComponent("data.mdb"))
        try manager.createSymbolicLink(at: nested.directory.appendingPathComponent("external"), withDestinationURL: outside)
        AudioCacheStore.removeJob(nested)
        try check(!manager.fileExists(atPath: nested.directory.path) && (try Data(contentsOf: sentinel)) == sentinelBytes, "Nested generated files are removed without following an external symlink")
        let baseLink = root.appendingPathComponent("CacheLink", isDirectory: true)
        try manager.createSymbolicLink(at: baseLink, withDestinationURL: outside)
        try rejects("Symlink cache roots are refused") { _ = try AudioCacheStore.createJob(in: baseLink) }
        try rejects("Symlink cache ancestors are refused") { _ = try AudioCacheStore.createJob(in: baseLink.appendingPathComponent("Nested")) }
        try check(!manager.fileExists(atPath: outside.appendingPathComponent("Nested").path), "Refusing a symlink ancestor creates nothing beyond it")

        let child = try holdChild(cache)
        try check(try AudioCacheStore.clearInactive(in: cache) == 0, "A live job in another process is preserved by its lock")
        try check(manager.fileExists(atPath: child.directory.path), "Cross-process cleanup does not unlink active PCM")
        child.process.terminate(); child.process.waitUntilExit()
        try check(manager.fileExists(atPath: child.directory.path), "A crash leaves a marked job for recovery")
        try check(try AudioCacheStore.clearInactive(in: cache) == 1 && !manager.fileExists(atPath: child.directory.path), "Released crash lock permits reclaiming only the abandoned job")
        let nextChild = try holdChild(cache)
        nextChild.process.terminate(); nextChild.process.waitUntilExit()
        let newJob = try AudioCacheStore.createJob(in: cache)
        try check(!manager.fileExists(atPath: nextChild.directory.path), "Starting a new comparison sweeps an abandoned job automatically")
        try check(manager.fileExists(atPath: second.directory.path) && manager.fileExists(atPath: newJob.directory.path), "Automatic recovery still preserves all live leases")
        AudioCacheStore.removeJob(second); AudioCacheStore.removeJob(newJob)
        try check((try Data(contentsOf: sentinel)) == sentinelBytes && manager.fileExists(atPath: unknown.path), "Final cleanup preserves unrelated original files")
        print("Audio cache checks: \(count) passed")
    }
    static func holdChild(_ cache: URL) throws -> (process: Process, directory: URL, input: Pipe) {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold", cache.path]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.standardError
        try child.run()
        // Foundation may try filling read(upToCount:) while the child deliberately
        // keeps stdout open. POSIX read returns the first available marker line.
        var bytes = [UInt8](repeating: 0, count: 4096)
        let amount = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        guard amount > 0,
              let path = String(data: Data(bytes.prefix(amount)), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix(cache.path + "/") else {
            child.terminate(); child.waitUntilExit(); throw Failure(description: "Cache child did not acquire a lease")
        }
        return (child, URL(fileURLWithPath: path, isDirectory: true), input)
    }
}

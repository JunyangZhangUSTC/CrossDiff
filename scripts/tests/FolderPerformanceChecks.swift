import Foundation

private final class FirstFolderResultTime: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval?
    func record() { lock.lock(); defer { lock.unlock() }; if time == nil { time = ProcessInfo.processInfo.systemUptime } }
    var value: TimeInterval? { lock.lock(); defer { lock.unlock() }; return time }
}

/// Reusable data sets; timings are diagnostic, while status/bytes-read assertions are deterministic.
@main enum FolderPerformanceChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/folder-performance/fixtures")
        let manager = FileManager.default
        let scenarios: [(name: String, count: Int, size: Int, difference: String)] = [
            ("1000-small", 1000, 4096, "none"),
            ("10000-small", 10000, 4096, "none"),
            ("64-large-same-total", 64, 640000, "none"),
            ("10000-different-size", 10000, 4096, "size"),
            ("64-large-one-sided", 64, 640000, "missing")
        ]
        for scenario in scenarios {
            let location = root.appendingPathComponent(scenario.name)
            let left = location.appendingPathComponent("left"), right = location.appendingPathComponent("right")
            for side in [left, right] {
                try manager.createDirectory(at: side, withIntermediateDirectories: true)
                if side == right && scenario.difference == "missing" { continue }
                let size = side == right && scenario.difference == "size" ? scenario.size / 2 : scenario.size
                let payload = Data(repeating: 0x61, count: size)
                for index in 0..<scenario.count {
                    let directory = side.appendingPathComponent(String(format: "group-%03d", index / 100))
                    if index % 100 == 0 { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
                    let file = directory.appendingPathComponent(String(format: "file-%06d.bin", index))
                    if !manager.fileExists(atPath: file.path) { try payload.write(to: file) }
                }
            }
            #if FOLDER_BASELINE
            let modes = ["baseline"]
            #else
            let modes = ["sync", "async-1", "async-2"]
            #endif
            for mode in modes {
                for pass in 1...2 {
                    let start = ProcessInfo.processInfo.systemUptime
                    let first = FirstFolderResultTime()
                    let result: FolderComparisonResult
                    #if FOLDER_BASELINE
                    result = try FolderComparison.scan(left: left, right: right)
                    #else
                    if mode == "sync" { result = try FolderComparison.scan(left: left, right: right) }
                    else {
                        result = try await FolderComparison.scanIncrementally(left: left, right: right,
                            options: FolderScanOptions(maxConcurrentReads: mode == "async-1" ? 1 : 2)) { update in
                                if update.result != nil { first.record() }
                            }
                    }
                    #endif
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    let expected: FolderEntryStatus = scenario.difference == "none" ? .same :
                        (scenario.difference == "size" ? .changed : .leftOnly)
                    precondition(result.entries.allSatisfy { $0.status == expected }, "Unexpected comparison result for \(scenario.name)")
                    let firstMilliseconds = (first.value.map { $0 - start } ?? elapsed) * 1000
                    #if FOLDER_BASELINE
                    let bytes = "unmeasured"
                    #else
                    let expectedBytes = scenario.difference == "none" ? Int64(scenario.count * scenario.size * 2) : 0
                    precondition(result.progress.bytesRead == expectedBytes, "Unnecessary content reads for \(scenario.name)")
                    precondition(result.isComplete)
                    let bytes = String(result.progress.bytesRead)
                    #endif
                    print("\(scenario.name) mode=\(mode) files-per-side=\(scenario.count) pass=\(pass) seconds=\(String(format: "%.3f", elapsed)) first-result-ms=\(String(format: "%.1f", firstMilliseconds)) bytes-read=\(bytes)")
                    fflush(stdout)
                }
            }
        }
    }
}

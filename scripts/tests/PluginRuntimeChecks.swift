import Foundation
import CrossDiffCore
import CryptoKit
import Darwin

@main
enum PluginRuntimeChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "PluginRuntimeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static let request = PluginComparisonRequest(runID: "runtime-check", inputs: [
        PluginInput(id: "left", role: .left, name: "left", content: .object(["text": .string("aab")])),
        PluginInput(id: "right", role: .right, name: "right", content: .object(["text": .string("bcc")]))
    ])

    static func package(script: String) throws -> PluginPackage {
        let manifest = PluginManifest(id: "org.example.runtime-check", version: "1.0.0",
            name: .init(zhHans: "检查", en: "Check"), summary: .init(zhHans: "检查", en: "Check"),
            runtime: .restrictedJavaScript, inputKind: .text, fileExtensions: ["txt"], resultView: "table")
        let manifestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
        let object: [String: Any] = ["formatVersion": 1, "manifest": manifestJSON, "script": script,
            "sha256": SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()]
        return try PluginPackage.decode(data: JSONSerialization.data(withJSONObject: object))
    }

    static let script = """
    function compare(request) {
        const left = new Set(Array.from(request.inputs[0].content.text));
        const right = new Set(Array.from(request.inputs[1].content.text));
        return {protocolVersion: 1, runID: request.runID, schema: 'crossdiff.table/1',
            status: 'completed', summary: {zhHans: '字符集合', en: 'Character sets'}, diagnostics: [],
            payload: {rows: [{label: 'Unique characters', state: 'changed',
                left: Array.from(left).filter(v => !right.has(v)).join(''),
                right: Array.from(right).filter(v => !left.has(v)).join('')}]}};
    }
    """

    static func main() async {
        do { try await checks() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func checks() async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let result = try await PluginRunner.run(package: package(script: script), request: request, helperURL: helper)
        try require(result.payload["rows"]?[0]?["left"]?.stringValue == "a", "Independent left difference was not preserved")
        try require(result.payload["rows"]?[0]?["right"]?.stringValue == "c", "Independent right difference was not preserved")
        print("PASS: public runner executes real third-party algorithm and validates its result")

        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await PluginRunner.run(package: package(script: "function compare() { for (;;) {} }"),
                request: request, helperURL: helper, limits: .init(timeout: 0.15))
            throw NSError(domain: "PluginRuntimeChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Infinite script was not terminated"])
        } catch PluginRunError.timedOut { }
        try require(ProcessInfo.processInfo.systemUptime - started < 2, "Timeout did not promptly release the worker")
        print("PASS: parent wall-clock deadline terminates an infinite worker promptly")

        let infinite = try package(script: "function compare() { for (;;) {} }")
        let cancellationStart = ProcessInfo.processInfo.systemUptime
        let running = Task {
            try await PluginRunner.run(package: infinite, request: request, helperURL: helper, limits: .init(timeout: 3))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        running.cancel()
        do {
            _ = try await running.value
            throw NSError(domain: "PluginRuntimeChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Canceled plugin returned a result"])
        } catch is CancellationError { }
        try require(ProcessInfo.processInfo.systemUptime - cancellationStart < 1, "Cancellation did not promptly release the worker")
        print("PASS: caller cancellation stops an infinite worker and returns no stale result")

        let memoryScript = script.replacingOccurrences(of: "function compare(request) {", with: """
        function compare(request) {
            globalThis.retained = new Uint8Array(64 * 1024 * 1024).fill(7);
            const until = Date.now() + 300;
            while (Date.now() < until) {}
        """)
        do {
            _ = try await PluginRunner.run(package: package(script: memoryScript), request: request, helperURL: helper,
                limits: .init(maximumResidentBytes: 32 * 1024 * 1024))
            throw NSError(domain: "PluginRuntimeChecks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Resident memory ceiling was not enforced"])
        } catch PluginRunError.memoryLimit { }
        print("PASS: parent resident-memory monitor stops an over-budget worker")

        let nativeURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let nativeBytes = try Data(contentsOf: nativeURL)
        let nativeManifest = PluginManifest(id: "org.example.native-check", version: "1.0.0",
            name: .init(zhHans: "原生检查", en: "Native check"), summary: .init(zhHans: "检查", en: "Check"),
            runtime: .trustedExecutable, inputKind: .text, fileExtensions: ["txt"], resultView: "table")
        let native = PluginPackage(manifest: nativeManifest, executable: nativeBytes,
            sha256: PluginPackage.digest(of: nativeBytes))
        do {
            _ = try await PluginRunner.run(package: native, request: request, helperURL: helper, nativeExecutableURL: nativeURL)
            throw NSError(domain: "PluginRuntimeChecks", code: 5, userInfo: [NSLocalizedDescriptionKey: "Native plugin ran without explicit trust"])
        } catch PluginValidationError.nativeTrustRequired { }
        let nativeResult = try await PluginRunner.run(package: native, request: request, helperURL: helper,
            nativeExecutableURL: nativeURL, approvedNativeDigest: native.sha256)
        try require(nativeResult.payload["rows"]?[0]?["left"]?.stringValue == "a", "Signed native algorithm did not execute")
        print("PASS: signed native execution requires explicit payload-bound full trust")

        do {
            _ = try await PluginRunner.run(package: native, request: request, helperURL: helper,
                nativeExecutableURL: nativeURL, approvedNativeDigest: String(repeating: "0", count: 64))
            throw NSError(domain: "PluginRuntimeChecks", code: 6, userInfo: [NSLocalizedDescriptionKey: "Trust for different bytes was accepted"])
        } catch PluginValidationError.nativeTrustRequired { }

        let fixtures = nativeURL.deletingLastPathComponent()
        let modifiedURL = fixtures.appendingPathComponent("modified-\(UUID().uuidString)")
        var modified = nativeBytes
        modified[modified.count / 2] ^= 1
        try modified.write(to: modifiedURL)
        defer { try? FileManager.default.removeItem(at: modifiedURL) }
        do {
            _ = try await PluginRunner.run(package: native, request: request, helperURL: helper,
                nativeExecutableURL: modifiedURL, approvedNativeDigest: native.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 7, userInfo: [NSLocalizedDescriptionKey: "Changed installed bytes were executed"])
        } catch PluginValidationError.digestMismatch { }
        let rehashed = PluginPackage(manifest: nativeManifest, executable: modified, sha256: PluginPackage.digest(of: modified))
        do {
            _ = try await PluginRunner.run(package: rehashed, request: request, helperURL: helper,
                nativeExecutableURL: modifiedURL, approvedNativeDigest: rehashed.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid code signature was accepted"])
        } catch PluginRunError.invalidCodeSignature { }
        print("PASS: changed executable digest and invalid native code signatures are rejected")

        let quarantinedURL = fixtures.appendingPathComponent("quarantined-\(UUID().uuidString)")
        try nativeBytes.write(to: quarantinedURL)
        defer { try? FileManager.default.removeItem(at: quarantinedURL) }
        let quarantine = Data("0081;00000000;CrossDiffRuntimeChecks;".utf8)
        let setResult = quarantine.withUnsafeBytes { bytes in
            setxattr(quarantinedURL.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
        }
        try require(setResult == 0, "Could not create quarantined fixture")
        do {
            _ = try await PluginRunner.run(package: native, request: request, helperURL: helper,
                nativeExecutableURL: quarantinedURL, approvedNativeDigest: native.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 9, userInfo: [NSLocalizedDescriptionKey: "Quarantined native code was launched"])
        } catch PluginRunError.quarantinedExecutable { }
        try require(getxattr(quarantinedURL.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.count,
            "Runtime removed quarantine metadata")
        print("PASS: quarantined native payload is not launched and its quarantine is preserved")

        do {
            _ = try await PluginRunner.run(package: package(script: script), request: request,
                helperURL: helper, limits: .init(maximumInputBytes: 64))
            throw NSError(domain: "PluginRuntimeChecks", code: 10, userInfo: [NSLocalizedDescriptionKey: "Parent accepted input beyond its budget"])
        } catch PluginRunError.inputLimit { }
        do {
            _ = try await PluginRunner.run(package: package(script: script), request: request,
                helperURL: helper, limits: .init(maximumOutputBytes: 64))
            throw NSError(domain: "PluginRuntimeChecks", code: 11, userInfo: [NSLocalizedDescriptionKey: "Parent accepted output beyond its budget"])
        } catch PluginRunError.outputLimit { }
        print("PASS: parent independently enforces input and output budgets")

        for invalidScript in [script.replacingOccurrences(of: "runID: request.runID", with: "runID: 'stale-run'"),
                              script.replacingOccurrences(of: "'crossdiff.table/1'", with: "'crossdiff.unknown/1'")] {
            do {
                _ = try await PluginRunner.run(package: package(script: invalidScript), request: request, helperURL: helper)
                throw NSError(domain: "PluginRuntimeChecks", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid result identity/schema was published"])
            } catch PluginValidationError.invalidField(_) { }
        }
        print("PASS: stale run identity and unknown result schema never reach the caller")

        let stderrRequest = PluginComparisonRequest(runID: "stderr-budget", inputs: request.inputs,
            options: ["fixtureMode": .string("stderr")])
        do {
            _ = try await PluginRunner.run(package: native, request: stderrRequest, helperURL: helper,
                nativeExecutableURL: nativeURL, approvedNativeDigest: native.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 13, userInfo: [NSLocalizedDescriptionKey: "Unbounded native stderr was accepted"])
        } catch PluginRunError.outputLimit { }
        let exitStderrRequest = PluginComparisonRequest(runID: "exit-stderr-budget", inputs: request.inputs,
            options: ["fixtureMode": .string("exit-stderr")])
        for _ in 0..<40 {
            do {
                _ = try await PluginRunner.run(package: native, request: exitStderrRequest, helperURL: helper,
                    nativeExecutableURL: nativeURL, approvedNativeDigest: native.sha256,
                    limits: .init(maximumStderrBytes: 128))
                throw NSError(domain: "PluginRuntimeChecks", code: 16, userInfo: [NSLocalizedDescriptionKey: "Native exit burst exceeded stderr budget but returned a result"])
            } catch PluginRunError.outputLimit { }
        }
        print("PASS: native exit-time stderr bursts cannot accompany a successful result beyond their budget")
        let malformedRequest = PluginComparisonRequest(runID: "malformed-output", inputs: request.inputs,
            options: ["fixtureMode": .string("malformed")])
        do {
            _ = try await PluginRunner.run(package: native, request: malformedRequest, helperURL: helper,
                nativeExecutableURL: nativeURL, approvedNativeDigest: native.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 14, userInfo: [NSLocalizedDescriptionKey: "Malformed native output was published"])
        } catch is DecodingError { }
        let failureRequest = PluginComparisonRequest(runID: "failed-executable", inputs: request.inputs,
            options: ["fixtureMode": .string("failure")])
        do {
            _ = try await PluginRunner.run(package: native, request: failureRequest, helperURL: helper,
                nativeExecutableURL: nativeURL, approvedNativeDigest: native.sha256)
            throw NSError(domain: "PluginRuntimeChecks", code: 15, userInfo: [NSLocalizedDescriptionKey: "Failed native process was accepted"])
        } catch PluginRunError.executionFailed { }
        _ = try await PluginRunner.run(package: package(script: script), request: request, helperURL: helper)
        print("PASS: native stderr, malformed output and process failures are contained; subsequent runs still work")
    }
}

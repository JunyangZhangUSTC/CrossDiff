import Foundation
import JavaScriptCore
import CrossDiffCore

@main enum VideoPluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func source(_ id: String, duration: VideoTime = .init(value: 6000, timescale: 600),
                       width: Int = 1920, height: Int = 1080, rate: Double = 30,
                       codec: String = "avc1", hasAudio: Bool = true, isHDR: Bool = false) -> VideoSourceMetadata {
        .init(id: id, name: "\(id).mov", duration: duration, width: width, height: height,
              nominalFrameRate: rate, codec: codec, hasAudio: hasAudio, isHDR: isHDR)
    }
    static func request(_ left: VideoSourceMetadata, _ right: VideoSourceMetadata,
                        options: [String: PluginJSONValue] = [:]) -> PluginComparisonRequest {
        .init(runID: "video-check", inputs: [.init(id: "left", role: .left, name: left.name, content: left.pluginContent),
                                            .init(id: "right", role: .right, name: right.name, content: right.pluginContent)], options: options)
    }
    static func changedResult(_ result: PluginComparisonResult, payload: [String: PluginJSONValue],
                              status: PluginResultStatus = .completed) -> PluginComparisonResult {
        .init(runID: result.runID, schema: result.schema, status: status,
              summary: result.summary, diagnostics: result.diagnostics, payload: .object(payload))
    }
    static func main() async throws {
        var invalidLoop = VideoWorkspaceState()
        invalidLoop.isLinked = false; invalidLoop.loopEnabled = true; invalidLoop.loopEnd = 1
        try check(!invalidLoop.isValid, "Unlinked playback cannot persist a paired loop")
        var invalidAnchors = VideoWorkspaceState()
        invalidAnchors.alignmentLeft = .init(value: 1, timescale: 1)
        try check(!invalidAnchors.isValid, "Alignment anchors must come in pairs")
        invalidAnchors.alignmentRight = .init(value: 3, timescale: 1)
        try check(!invalidAnchors.isValid, "Anchor mapping must agree with displayed offset")
        invalidAnchors.offsetSeconds = 2
        try check(invalidAnchors.isValid, "Exact source anchors preserve a valid manual offset")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = root.appendingPathComponent("Plugins/Official/Video")
        let script = try String(contentsOf: directory.appendingPathComponent("compare.js"), encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let package = PluginPackage(manifest: manifest, script: script, sha256: PluginPackage.digest(of: Data(script.utf8)))
        try package.validate()
        try check(manifest.id == "org.crossdiff.video" && manifest.resultSchema == "crossdiff.video/1"
                  && manifest.inputKind == .videoAnalysis && manifest.version == "0.1.0", "Official video package declares its own metadata domain")
        let context = JSContext()!
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        try check(exception == nil, "Official JavaScript loads without errors")
        func runJS(_ input: Any) throws -> PluginComparisonResult {
            exception = nil
            guard let object = context.objectForKeyedSubscript("compare")?.call(withArguments: [input])?.toDictionary(), exception == nil else {
                throw Failure(description: exception ?? "Video plugin returned no result")
            }
            return try JSONDecoder().decode(PluginComparisonResult.self, from: JSONSerialization.data(withJSONObject: object))
        }
        func run(_ request: PluginComparisonRequest) throws -> PluginComparisonResult {
            try request.validate(for: manifest)
            let raw = try runJS(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)))
            try raw.validate(for: request, manifest: manifest)
            return raw
        }
        let left = source("A"), right = source("B")
        let req = request(left, right), raw = try run(req)
        let parsed = try VideoComparisonResult.parse(raw)
        try check(parsed.metadataDifferences.isEmpty && raw.payload["contentCompared"]?.boolValue == false,
                  "Identical metadata does not imply identical video content")
        try check(parsed.summary.en == "Listed technical metadata matches" && parsed.summary.zhHans == "所列技术信息一致",
                  "Both languages explicitly scope equality to listed technical metadata")
        try check(parsed.diagnostics.contains { $0.en.contains("does not mean matching pictures") && $0.zhHans.contains("不代表画面相同") },
                  "Result explains the limit without fabricating temporal correspondence")
        let helperResult = try await PluginRunner.run(package: package, request: req,
            helperURL: root.appendingPathComponent(".build-video-plugin-checks/CrossDiffPluginHost"))
        try check(try VideoComparisonResult.parse(helperResult) == parsed, "Real restricted subprocess preserves the same validated facts")
        let durationTimebase = source("B", duration: .init(value: 10000, timescale: 1000))
        try check(try VideoComparisonResult.parse(run(request(left, durationTimebase))).metadataDifferences.isEmpty,
                  "Equivalent duration with another timescale is not a content or metadata difference")
        let changed = source("B", duration: .init(value: 6600, timescale: 600), width: 1280, height: 720,
                             rate: 29.97, codec: "hvc1", hasAudio: false, isHDR: true)
        let different = try VideoComparisonResult.parse(run(request(left, changed)))
        try check(different.metadataDifferences == VideoContract.metadataFields, "Codec, dimensions, rate, audio, HDR and duration differences retain a stable factual order")
        let maximumTime = VideoTime(value: 86400 * Int64(Int32.max), timescale: Int32.max)
        let maximumSource = source("max", duration: maximumTime)
        try check(maximumSource.isValid && (try VideoContract.metadata(maximumSource.pluginContent)) == maximumSource,
                  "Maximum accepted duration retains a precise rational representation")
        try check(try VideoComparisonResult.parse(run(request(maximumSource, source("day", duration: .init(value: 86400, timescale: 1))))).metadataDifferences.isEmpty,
                  "Exact duration equivalence remains correct at the maximum timescale")
        let nearMaximum = source("near", duration: .init(value: maximumTime.value - 1, timescale: Int32.max))
        try check(try VideoComparisonResult.parse(run(request(maximumSource, nearMaximum))).metadataDifferences == ["duration"],
                  "A one-tick source duration difference is not rounded away")
        let hugeTime = VideoTime(value: 9007199254740993, timescale: 600)
        let hugeRoundTrip = try JSONDecoder().decode(VideoTime.self, from: JSONEncoder().encode(hugeTime))
        try check(hugeRoundTrip == hugeTime && hugeTime.pluginContent["value"]?.stringValue == "9007199254740993",
                  "Time transport preserves Int64 values beyond JavaScript number precision")
        try check(!source("huge", duration: hugeTime).isValid, "Lossless time representation does not bypass the duration resource limit")
        try check(!VideoTime(value: 0, timescale: 0).isValid && !VideoTime(value: -1, timescale: 600).isValid,
                  "Nonpositive scales and negative source positions are rejected")
        try check(VideoTime(value: 0, timescale: 600).isEquivalent(to: .init(value: 0, timescale: 1000)),
                  "Origin time equivalence never divides by zero")
        for value in [VideoTime(value: 0, timescale: 600), .init(value: 86401, timescale: 1), .init(value: 1, timescale: 0)] {
            try check(!source("invalid", duration: value).isValid, "Zero, excessive or invalid-scale durations fail explicitly")
        }
        for rate in [-1.0, .nan, .infinity, 1001] {
            try check(!source("invalid", rate: rate).isValid, "Invalid nominal frame rate is rejected")
        }
        try check(source("unknown-rate", rate: 0).isValid, "An unavailable nominal rate remains zero rather than fabricated FPS")
        try check(!source("invalid", width: 0).isValid && !source("invalid", height: 32769).isValid,
                  "Source dimensions are positive and bounded")
        for badValue: PluginJSONValue in [.number(6000), .string("06000"), .string("+6000"), .string("6000.0"), .string("9223372036854775808")] {
            var metadata = left.pluginContent.objectValue!
            metadata["duration"] = .object(["value": badValue, "timescale": .number(600)])
            try rejects("Duration is an exact canonical nonnegative Int64 decimal string") { try VideoContract.validateInput(.object(metadata)) }
        }
        for (key, value): (String, PluginJSONValue) in [
            ("url", .string("file:///private/source.mov")), ("frames", .array([])), ("audio", .array([])),
            ("correspondences", .array([]))] {
            var metadata = left.pluginContent.objectValue!; metadata[key] = value
            try rejects("Unexpected input capability \(key) is rejected") { try VideoContract.validateInput(.object(metadata)) }
        }
        try rejects("Video options cannot request arbitrary file or content analysis") {
            try request(left, right, options: ["path": .string("source.mov")]).validate(for: manifest)
        }
        let wrongView = PluginManifest(id: manifest.id, version: manifest.version, name: manifest.name,
            summary: manifest.summary, runtime: manifest.runtime, inputKind: .videoAnalysis,
            fileExtensions: manifest.fileExtensions, resultView: "audioTimeline")
        try rejects("Video inputs cannot acquire the audio renderer") { try wrongView.validate() }
        let wrongMode = PluginManifest(id: manifest.id, version: manifest.version, name: manifest.name,
            summary: manifest.summary, runtime: manifest.runtime, inputKind: .videoAnalysis,
            fileExtensions: manifest.fileExtensions, resultView: "videoTimeline", supportedModes: [.pairwise, .multiSubject])
        try rejects("Video currently supports precisely two sources") { try wrongMode.validate() }
        var payload = raw.payload.objectValue!
        payload["contentCompared"] = .bool(true)
        try rejects("Plugin cannot claim to compare frames from metadata") { try changedResult(raw, payload: payload).validate(for: req, manifest: manifest) }
        for fields in [["duration"], ["sameVideo"], ["duration", "duration"]] {
            payload = raw.payload.objectValue!; payload["metadataDifferences"] = .array(fields.map(PluginJSONValue.string))
            try rejects("Forged or repeated metadata claims are rejected") { try changedResult(raw, payload: payload).validate(for: req, manifest: manifest) }
        }
        payload = raw.payload.objectValue!; payload["correspondences"] = .array([])
        try rejects("Plugin cannot add invented temporal correspondence") { try changedResult(raw, payload: payload).validate(for: req, manifest: manifest) }
        try rejects("Incomplete results do not masquerade as completed metadata") {
            try changedResult(raw, payload: raw.payload.objectValue!, status: .partial).validate(for: req, manifest: manifest)
        }
        let wrongRun = PluginComparisonResult(runID: "stale", schema: raw.schema, summary: raw.summary, payload: raw.payload)
        try rejects("A stale plugin response cannot replace a current request") { try wrongRun.validate(for: req, manifest: manifest) }
        let wrongSchema = PluginComparisonResult(runID: raw.runID, schema: "crossdiff.audio/1", summary: raw.summary, payload: raw.payload)
        try rejects("Audio payloads cannot be interpreted as video metadata") { _ = try VideoComparisonResult.parse(wrongSchema) }
        // Exercise the distributed JS directly as well as host-side validation.
        var requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        requestObject["options"] = ["correspondences": []]
        try rejects("Official JavaScript independently rejects unsupported analysis options") { _ = try runJS(requestObject) }
        requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        var inputObjects = requestObject["inputs"] as! [[String: Any]]
        var firstContent = inputObjects[0]["content"] as! [String: Any]
        firstContent["path"] = "source.mov"; inputObjects[0]["content"] = firstContent; requestObject["inputs"] = inputObjects
        try rejects("Official JavaScript independently rejects file paths") { _ = try runJS(requestObject) }
        let storeURL = root.appendingPathComponent(".build-video-plugin-checks/fixtures/store-\(UUID().uuidString)")
        let store = try PluginStore(root: storeURL)
        _ = try store.install(PluginPackage.decode(data: package.encoded()))
        try check(store.list().contains { $0.id == manifest.id }, "Base can install the independent video package")
        print("Video plugin checks: \(count) passed")
    }
}

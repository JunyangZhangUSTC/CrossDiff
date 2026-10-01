import Foundation
import JavaScriptCore
import CrossDiffCore

@main
enum PhotographyPluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
        count += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; return }
        throw Failure(description: message)
    }
    static func bins(_ position: Int, count: Int = 256, weight: Double = 1) -> [Double] {
        var bins = Array(repeating: 0.0, count: count); bins[position] = weight; return bins
    }
    static func statistics(lightness: Int, saturation: Int = 0, sampled: Bool = false) -> PhotoStatistics {
        let neutral = saturation < 5 ? 1.0 : 0.0
        return PhotoStatistics(red: bins(lightness), green: bins(lightness), blue: bins(lightness),
            lightness: bins(lightness), hue: bins(30, count: 360, weight: 1 - neutral), saturation: bins(saturation),
            neutralFraction: neutral, analyzedPixels: 4096, sampleWidth: 64, sampleHeight: 64, sampled: sampled,
            analysisSpace: "sRGB · SDR [0, 1] · HSL lightness · OpenCV 4.12.0")
    }
    static func request(_ left: PluginJSONValue, _ right: PluginJSONValue) -> PluginComparisonRequest {
        .init(runID: "photo-check", inputs: [.init(id: "left", role: .left, name: "left.png", content: left),
                                          .init(id: "right", role: .right, name: "right.png", content: right)])
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = root.appendingPathComponent(".build-photography-plugin-checks", isDirectory: true)
        let package = try PluginPackage.load(from: output.appendingPathComponent("Photography.crossdiffplugin"))
        let script = try String(contentsOf: root.appendingPathComponent("Plugins/Official/Photography/compare.js"), encoding: .utf8)
        try check(package.manifest.id == "org.crossdiff.photography" && package.script == script,
                  "Standalone package preserves official identity and exact algorithm")
        try check(package.manifest.inputKind == .photoAnalysis && package.manifest.resultSchema == "crossdiff.photography/1",
                  "Photographic statistics have a dedicated input kind and native result contract")
        try check(package.manifest.minHostProtocol == 1 && PluginProtocol.version == 1,
                  "Adding a capability preserves existing plugin protocol versions")
        let dark = statistics(lightness: 0).pluginContent
        let bright = statistics(lightness: 255, saturation: 255, sampled: true).pluginContent
        let original = request(dark, bright)
        try original.validate(for: package.manifest)
        let context = JSContext()!
        var scriptFailure: String?
        context.exceptionHandler = { _, value in scriptFailure = value?.toString() }
        context.evaluateScript(script)
        try check(scriptFailure == nil, "Photography algorithm parses in JavaScriptCore")
        func run(_ request: PluginComparisonRequest) throws -> PluginComparisonResult {
            scriptFailure = nil
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
            guard let result = context.objectForKeyedSubscript("compare")?.call(withArguments: [object])?.toDictionary(), scriptFailure == nil else {
                throw Failure(description: scriptFailure ?? "Missing result")
            }
            let decoded = try JSONDecoder().decode(PluginComparisonResult.self, from: JSONSerialization.data(withJSONObject: result))
            try decoded.validate(for: request, manifest: package.manifest)
            return decoded
        }
        let result = try run(original)
        let findings = result.payload["findings"]!.arrayValue!
        try check(findings.count == 4 && findings.allSatisfy { $0["zhHans"]?.stringValue != nil && $0["en"]?.stringValue != nil },
                  "Every distribution explanation is available in Chinese and English")
        try check(findings[0]["en"]!.stringValue!.contains("100.0 percentage points lower") &&
                  findings[1]["en"]!.stringValue!.contains("100.0 percentage points higher"),
                  "Known dark and bright distributions report the correct direction and percentage points")
        try check(findings[2]["en"]!.stringValue!.contains("100.0 percentage points higher") &&
                  findings[3]["en"]!.stringValue!.contains("100.0 percentage points lower"),
                  "Saturation and neutral shares follow the supplied library histograms")
        try check(result.diagnostics.count == 2 && result.diagnostics.last!.en.contains("sampled pixels"),
                  "Sampled analysis is disclosed rather than claimed to cover every original pixel")
        let equal = try run(request(dark, dark))
        try check(equal.payload["findings"]!.arrayValue!.allSatisfy { $0["en"]!.stringValue!.contains("less than 1 percentage point") },
                  "Identical distributions never imply identical pixels or identical photographic quality")
        try check(equal.diagnostics.count == 1, "Full-resolution aggregate input does not acquire a sampling warning")
        let reversed = try run(request(bright, dark))
        try check(reversed.payload["findings"]![0]!["en"]!.stringValue!.contains("100.0 percentage points higher"),
                  "Swapping sides reverses the explanation")
        for (field, value) in [("lightness", PluginJSONValue.array([.number(1)])),
                               ("red", .array(bins(0, weight: 0.5).map(PluginJSONValue.number))),
                               ("neutralFraction", .number(-1)), ("analyzedPixels", .number(0)),
                               ("sampled", .string("true")), ("hue", .array(bins(30, count: 360).map(PluginJSONValue.number)))] {
            var altered = dark.objectValue!; altered[field] = value
            let malformed = request(.object(altered), bright)
            try rejects("Host must reject malformed \(field)") { try malformed.validate(for: package.manifest) }
            try rejects("Algorithm must reject malformed \(field)") { _ = try run(malformed) }
        }
        var differentSpace = bright.objectValue!; differentSpace["analysisSpace"] = .string("Different working space")
        let incompatible = request(dark, .object(differentSpace))
        try rejects("Host must reject inconsistent analysis spaces") { try incompatible.validate(for: package.manifest) }
        try rejects("Algorithm must reject inconsistent analysis spaces") { _ = try run(incompatible) }
        var manifestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(package.manifest)) as! [String: Any]
        for (field, value) in [("resultView", "table" as Any), ("supportedModes", ["multiSubject"] as Any)] {
            var invalid = manifestObject; invalid[field] = value
            let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: invalid))
            try rejects("Unsupported photograph manifest \(field) must be rejected") { try decoded.validate() }
        }
        manifestObject["inputKind"] = "text"
        let incorrectKind = try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: manifestObject))
        try rejects("Photography renderer cannot receive arbitrary text") { try incorrectKind.validate() }
        for payload in [PluginJSONValue.object(["findings": .array(Array(repeating: findings[0], count: 9))]),
                        .object(["findings": .array([.object(["zhHans": .string("缺英文")])])]),
                        .object(["findings": .array([.object(["zhHans": .string("过长"), "en": .string(String(repeating: "x", count: 2049))])])])] {
            let invalid = PluginComparisonResult(runID: original.runID, schema: result.schema, summary: result.summary, payload: payload)
            try rejects("Host bounds and localizes every photography finding") { try invalid.validate(for: original, manifest: package.manifest) }
        }
        var state = PhotoWorkspaceState()
        state.leftRegion = .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        state.rightRegion = .init(x: 0.5, y: 0.1, width: 0.2, height: 0.6)
        state.linkedRegions = true
        state.regions = [.init(name: "天空 / Sky", left: state.leftRegion, right: state.rightRegion),
                         .init(name: "肤色 / Skin", left: .full, right: .full)]
        state.leftXMPPath = output.appendingPathComponent("example.xmp").path
        let record = StoredComparison(kind: "plugin", left: .init(path: "left.png"), right: .init(path: "right.png"),
                                      pluginID: package.manifest.id, photoState: state)
        let sessionsURL = output.appendingPathComponent("fixtures/sessions.json")
        try SessionFile.save([record], to: sessionsURL)
        let restored = try SessionFile.load(from: sessionsURL)[0]
        try check(restored.photoState == state && restored.left.text.isEmpty && restored.right.text.isEmpty,
                  "Named region pairs, link state and selected sidecar restore without entering source text")
        var oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        oldRecord.removeValue(forKey: "photoState")
        let old = try JSONDecoder().decode(StoredComparison.self, from: JSONSerialization.data(withJSONObject: oldRecord))
        try check(old.photoState == nil, "Sessions from previous versions restore without photographic state")
        var invalidState = state; invalidState.regions[0].left.width = 2
        try check(!invalidState.isValid, "Out-of-bounds restored selections cannot enter the native model")
        let pdf = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: root.appendingPathComponent("Plugins/PDF/manifest.json")))
        try pdf.validate()
        try check(pdf.resultSchema == "crossdiff.document-pages/1", "Existing PDF manifests remain compatible")
        print("Photography plugin checks: \(count) passed")
    }
}

import Foundation
import JavaScriptCore
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let maximumInputBytes = 32 * 1024 * 1024
var data = Data()
while let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
    guard data.count <= maximumInputBytes - chunk.count else { fail("Plugin input exceeds the limit.") }
    data.append(chunk)
}
guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let script = envelope["script"] as? String,
      let request = envelope["request"] as? [String: Any],
      let requestData = try? JSONSerialization.data(withJSONObject: request),
      let requestText = String(data: requestData, encoding: .utf8),
      let literalData = try? JSONSerialization.data(withJSONObject: [requestText]),
      let literalArray = String(data: literalData, encoding: .utf8),
      let context = JSContext() else {
    fail("Invalid plugin input.")
}

// This is a resource ceiling, not an OS sandbox. The parent also enforces wall time.
let cpuSeconds = min(30, max(1, (envelope["cpuTimeLimitSeconds"] as? Int) ?? 30))
var cpuLimit = rlimit(rlim_cur: rlim_t(cpuSeconds), rlim_max: rlim_t(cpuSeconds + 1))
guard setrlimit(RLIMIT_CPU, &cpuLimit) == 0 else { fail("Could not apply the plugin CPU limit.") }
var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
guard setrlimit(RLIMIT_CORE, &coreLimit) == 0 else { fail("Could not disable plugin core dumps.") }

// Only JSON text crosses into JavaScript. No native objects or callbacks are exposed.
context.evaluateScript(script)
guard context.exception == nil else { fail("Plugin script evaluation failed.") }
let value = context.evaluateScript("JSON.stringify(compare(JSON.parse(\(literalArray)[0])))")
guard context.exception == nil, let value, value.isString else {
    fail("Plugin comparison failed or returned no JSON result.")
}
let maximumOutputBytes = 8 * 1024 * 1024
guard let length = value.forProperty("length"), length.toDouble() <= Double(maximumOutputBytes),
      let output = value.toString()?.data(using: .utf8) else {
    fail("Plugin output exceeds the limit.")
}
guard output.count <= maximumOutputBytes else { fail("Plugin output exceeds the limit.") }
FileHandle.standardOutput.write(output)

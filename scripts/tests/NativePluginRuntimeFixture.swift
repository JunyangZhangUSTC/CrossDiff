import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
let request = try JSONSerialization.jsonObject(with: input) as! [String: Any]
let fixtureMode = (request["options"] as? [String: Any])?["fixtureMode"] as? String
if fixtureMode == "stderr" {
    FileHandle.standardError.write(Data(repeating: 120, count: 32 * 1024))
    exit(1)
}
if fixtureMode == "malformed" {
    FileHandle.standardOutput.write(Data("not a JSON result".utf8))
    exit(0)
}
if fixtureMode == "failure" { exit(7) }
let inputs = request["inputs"] as! [[String: Any]]
let left = Set((inputs[0]["content"] as! [String: Any])["text"] as! String)
let right = Set((inputs[1]["content"] as! [String: Any])["text"] as! String)
let result: [String: Any] = [
    "protocolVersion": 1, "runID": request["runID"]!, "schema": "crossdiff.table/1",
    "status": "completed", "summary": ["zhHans": "原生字符集合", "en": "Native character sets"],
    "diagnostics": [], "payload": ["rows": [["label": "Unique characters", "state": "changed",
        "left": String(left.subtracting(right).sorted()), "right": String(right.subtracting(left).sorted())]]]
]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))

if fixtureMode == "exit-stderr" {
    FileHandle.standardError.write(Data(repeating: 120, count: 511))
    exit(0)
}

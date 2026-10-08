import Foundation
import JavaScriptCore

let context = JSContext()!
var response: String?
let complete: @convention(block) (String) -> Void = { response = $0 }
context.setObject(complete, forKeyedSubscript: "peelComplete" as NSString)
context.exceptionHandler = { _, exception in
  let message = exception?.toString() ?? "JavaScript error"
  let payload: [String: Any] = ["status": "error", "text": message, "structured": false]
  response = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
}
let runtime =
  (Bundle.module.url(forResource: "runtime", withExtension: "js")
  ?? Bundle.module.url(forResource: "runtime", withExtension: "js", subdirectory: "Resources"))!
context.evaluateScript(try String(contentsOf: runtime, encoding: .utf8))
let request = FileHandle.standardInput.readDataToEndOfFile()
context.objectForKeyedSubscript("PeelRuntime")?.objectForKeyedSubscript("run")?.call(
  withArguments: [String(decoding: request, as: UTF8.self)])
while response == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
FileHandle.standardOutput.write(Data(response!.utf8))

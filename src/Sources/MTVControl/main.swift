import Foundation
import MTVCore

let args = Array(CommandLine.arguments.dropFirst())
do {
  let command: String
  var arguments: [String: String] = [:]
  switch args.first {
  case "status" where args.count == 1: command = "status"
  case "modules" where args.count == 1: command = "modules"
  case "library" where args.count == 1: command = "library.list"
  case "items" where args.count == 1: command = "module.list"
  case "navigate" where args.count == 2: command = "navigate"; arguments = ["section": args[1]]
  case "key" where args.count == 2: command = "input.key"; arguments = ["key": args[1]]
  case "open" where args.count == 2: command = "module.open"; arguments = ["plugin": args[1]]
  case "activate" where args.count == 2: command = "item.activate"; arguments = ["id": args[1]]
  case "login" where args.count == 2: command = "account.open"; arguments = ["plugin": args[1]]
  case "import-chrome" where args.count == 2: command = "account.importChrome"; arguments = ["plugin": args[1]]
  case "events" where args.count <= 2: command = "events"; arguments = ["after": args.count == 2 ? args[1] : "0"]
  case "call" where args.count == 2:
    guard let data = args[1].data(using: .utf8), data.count <= 32768,
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(value.keys).isSubset(of: ["command", "arguments"]), let operation = value["command"] as? String
    else { throw MTVError.code("invalid-control-command") }
    command = operation
    if let value = value["arguments"] {
      guard let supplied = value as? [String: String] else { throw MTVError.code("invalid-control-arguments") }
      arguments = supplied
    }
  default:
    throw MTVError.message("usage: mtvctl status|modules|library|items|navigate SECTION|key KEY|open PLUGIN|activate ID|login PLUGIN|import-chrome PLUGIN|events [AFTER]|call JSON")
  }
  let request = LocalControlRequest(command: command, arguments: arguments)
  try request.validate()
  let data = try LocalControlClient.send(request)
  let value = try JSONSerialization.jsonObject(with: data)
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) + Data([10]))
  exit((value as? [String: Any])?["ok"] as? Bool == true ? 0 : 1)
} catch {
  FileHandle.standardError.write(LocalControlJSON.encode(["schema": 1, "ok": false,
    "error": LocalControlJSON.safeText(error.localizedDescription)]) + Data([10]))
  exit(1)
}

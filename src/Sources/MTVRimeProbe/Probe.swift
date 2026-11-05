import Foundation
import RimeBridge

@main enum Probe {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw NSError(
        domain: "MTVRimeProbe", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Pass the engine resource root"])
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-rime-probe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var error = [CChar](repeating: 0, count: 2048)
    guard
      let engine = mtv_rime_create(CommandLine.arguments[1], directory.path, &error, error.count)
    else {
      throw NSError(
        domain: "MTVRimeProbe", code: 2,
        userInfo: [NSLocalizedDescriptionKey: String(cString: error)])
    }
    defer { mtv_rime_destroy(engine) }
    func state(_ operation: Int32 = 0, _ argument: Int32 = 0) -> (
      input: String, preedit: String, candidates: [String], commit: String, page: Int, last: Bool
    ) {
      let result = mtv_rime_apply(engine, operation, argument)!
      defer { mtv_rime_free_result(result) }
      return (
        String(cString: mtv_rime_input(result)), String(cString: mtv_rime_preedit(result)),
        (0..<mtv_rime_count(result)).map { String(cString: mtv_rime_candidate(result, $0)) },
        String(cString: mtv_rime_commit(result)), Int(mtv_rime_page(result)),
        mtv_rime_last_page(result) != 0
      )
    }
    var checks: [String: Bool] = [:]
    var examples: [String: [String]] = [:]
    for (input, expected) in [("nihao", "你好"), ("tianqihenhao", "天气很好"), ("xi'an", "西安")] {
      _ = state(3)
      for character in input.utf8 { _ = state(1, Int32(character)) }
      let snapshot = state()
      examples[input] = snapshot.candidates
      checks[input] = snapshot.candidates.contains(expected)
      let selected = state(2, Int32(snapshot.candidates.firstIndex(of: expected) ?? 0))
      checks[input + "-commit"] = selected.commit == expected && selected.input.isEmpty
    }
    _ = state(3)
    for character in "wojintianxiangqukandianying".utf8 { _ = state(1, Int32(character)) }
    let sentence = state()
    examples["sentence-first-segment"] = sentence.candidates
    if let index = sentence.candidates.firstIndex(of: "我今天") {
      let partial = state(2, Int32(index))
      examples["sentence-after-selection"] = partial.candidates
      checks["partialSelectionRetainsComposition"] =
        partial.commit.isEmpty && partial.preedit.contains("我今天") && !partial.input.isEmpty
      if let next = partial.candidates.firstIndex(of: "想去看电影") {
        checks["sentenceCommitAfterSegmentSelection"] = state(2, Int32(next)).commit == "我今天想去看电影"
      } else {
        checks["sentenceCommitAfterSegmentSelection"] = false
      }
    } else {
      checks["partialSelectionRetainsComposition"] = false
      checks["sentenceCommitAfterSegmentSelection"] = false
    }
    _ = state(3)
    for character in "shi".utf8 { _ = state(1, Int32(character)) }
    let first = state()
    let second = state(1, 0xff56)
    checks["nextPage"] =
      first.page == 0 && !first.last && second.page == 1 && second.candidates != first.candidates
    checks["previousPage"] = state(1, 0xff55).candidates == first.candidates
    _ = state(1, 0xff08)
    checks["backspace"] = state().input == "sh"
    _ = state(3)
    checks["clear"] = state().input.isEmpty && state().candidates.isEmpty
    let report: [String: Any] = [
      "engine": String(cString: mtv_rime_version(engine)), "checks": checks,
      "examples": examples, "passed": checks.values.allSatisfy { $0 }, "systemIMEChanged": false,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    if checks.values.contains(false) { exit(1) }
  }
}

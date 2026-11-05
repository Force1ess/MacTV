import Foundation
import MTVCore

let args = CommandLine.arguments
guard (args.count == 3 && args[1] == "summary") || (args.count == 4 && args[1] == "compare") else {
  FileHandle.standardError.write(Data("Usage: MTVBenchmark summary <records.jsonl> | compare <baseline.jsonl> <candidate.jsonl>\n".utf8)); exit(2)
}
do {
  func load(_ path: String) throws -> [PlaybackBenchmarkRecord] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
    return try data.split(separator: 10).map { try JSONDecoder().decode(PlaybackBenchmarkRecord.self, from: Data($0)) }
  }
  let records = try load(args[2])
  var result: [String: Any] = PlaybackBenchmarkRecord.summary(records)
  if args[1] == "compare" {
    let candidate = try load(args[3])
    guard PlaybackBenchmarkRecord.comparisonCompatible(records, candidate) else {
      throw MTVError.message("Comparison requires matching content, session, quality and observation/completion policy")
    }
    let before = PlaybackBenchmarkRecord.summary(records), after = PlaybackBenchmarkRecord.summary(candidate)
    result = ["baseline": before, "candidate": after]
    if let a = before["p50MS"], let b = after["p50MS"] { result["p50ChangeMS"] = b - a }
    if let a = before["p95MS"], let b = after["p95MS"] { result["p95ChangeMS"] = b - a }
  }
  print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch { FileHandle.standardError.write(Data("Benchmark read failed: \(error.localizedDescription)\n".utf8)); exit(1) }

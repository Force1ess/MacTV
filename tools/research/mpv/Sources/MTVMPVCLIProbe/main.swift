import Darwin
import Foundation

final class Client {
  let socket: Int32
  var buffer = Data(), nextID = 0
  init(path: String) throws {
    socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw CocoaError(.fileReadUnknown) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let name = Array(path.utf8) + [0]
    guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(socket); throw CocoaError(.fileReadInvalidFileName) }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(socket,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1; setsockopt(socket,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,4)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { close(socket); throw CocoaError(.fileReadUnknown) }
  }
  deinit { close(socket) }
  func request(_ command: [Any]) throws -> [String: Any] {
    nextID += 1
    let data = try JSONSerialization.data(withJSONObject: ["command":command,"request_id":nextID]) + Data([10])
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(socket,bytes.baseAddress!.advanced(by: offset),bytes.count-offset)
        guard count > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += count
      }
    }
    for _ in 0..<200 {
      if let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
        if let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any], reply["request_id"] as? Int == nextID { return reply }
      } else {
        var bytes = [UInt8](repeating: 0,count: 8192)
        let count = Darwin.read(socket,&bytes,bytes.count)
        guard count > 0, buffer.count + count < 1048576 else { throw CocoaError(.fileReadUnknown) }
        buffer.append(contentsOf: bytes.prefix(count))
      }
    }
    throw CocoaError(.fileReadUnknown)
  }
}
guard CommandLine.arguments.count == 4 else { exit(2) }
let args = CommandLine.arguments, output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
var report: [String: Any] = ["sourceUnmodified":true,"muted":true,"productionIntegration":false]
do {
  try FileManager.default.createDirectory(at: output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let socketPath = output.appendingPathComponent("ipc").path
  let process = Process()
  process.executableURL = URL(fileURLWithPath: args[1])
  process.arguments = ["--no-config","--vo=gpu-next","--gpu-api=vulkan","--mute=yes","--start=60","--osc=no",
    "--resume-playback=no","--save-position-on-quit=no","--input-ipc-server=" + socketPath,"--idle=yes",
    "--log-file=" + output.appendingPathComponent("mpv.log").path,args[2]]
  let log = output.appendingPathComponent("process.log")
  FileManager.default.createFile(atPath: log.path,contents: nil)
  let handle = try FileHandle(forWritingTo:log); defer { try? handle.close() }
  process.standardOutput = handle; process.standardError = handle
  try process.run()
  defer { if process.isRunning { process.terminate() } }
  var client: Client?
  for _ in 0..<100 {
    if let value = try? Client(path:socketPath) { client = value; break }
    Thread.sleep(forTimeInterval:0.05)
  }
  guard let client else { throw CocoaError(.fileReadUnknown) }
  for _ in 0..<200 {
    let position = (try? client.request(["get_property","time-pos"])["data"] as? Double) ?? 0
    if position > 62 { break }
    Thread.sleep(forTimeInterval:0.1)
  }
  report["pause"] = try client.request(["set_property","pause",true])["error"]
  report["seek"] = try client.request(["seek",62,"absolute+exact"])["error"]
  Thread.sleep(forTimeInterval:1)
  for key in ["mpv-version","current-vo","time-pos","duration","video-codec","video-params","video-out-params","hwdec-current","audio-codec-name"] {
    report[key] = try client.request(["get_property",key])["data"]
  }
  report["windowScreenshot"] = try client.request(["screenshot-to-file",output.appendingPathComponent("rendered-window.png").path,"window"])["error"]
  report["videoScreenshot"] = try client.request(["screenshot-to-file",output.appendingPathComponent("video.png").path,"video"])["error"]
  _ = try? client.request(["quit"])
} catch { report["error"] = error.localizedDescription }
if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
  try? data.write(to:output.appendingPathComponent("result.json"))
}

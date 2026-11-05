import Darwin
import Foundation

enum IsolationProbe {
  static func runIfRequested() throws {
    guard CommandLine.arguments.dropFirst().first == "--isolation-probe" else { return }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 16_384, let values = try JSONSerialization.jsonObject(with: input) as? [String: String],
      let readPath = values["read"], let writePath = values["write"], readPath.hasPrefix("/"), writePath.hasPrefix("/") else { exit(2) }
    let readable = (try? Data(contentsOf: URL(fileURLWithPath: readPath))) != nil
    errno = 0
    let file = writePath.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
    let error = errno
    if file >= 0 { close(file) }
    let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
    child.arguments = [writePath + "-child"]
    child.standardError = FileHandle.nullDevice
    var childStatus: Int32 = -1
    do { try child.run(); child.waitUntilExit(); childStatus = child.terminationStatus } catch {}
    var networkAllowed = false, networkError: Int32 = -1
    if let text = values["port"], let port = UInt16(text), port > 0 {
      let socketFD = socket(AF_INET, SOCK_STREAM, 0)
      if socketFD >= 0 {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        networkError = connected == 0 ? 0 : errno; networkAllowed = connected == 0; close(socketFD)
      } else { networkError = errno }
    }
    let output: [String: Any] = ["pid": getpid(), "readAllowed": readable, "writeAllowed": file >= 0,
      "writeErrno": error, "childStatus": childStatus,
      "networkAllowed": networkAllowed, "networkErrno": networkError,
      "containerEnvironmentPresent": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    exit(0)
  }
}

import Darwin
import Foundation

public struct LocalControlRequest: Codable, Sendable {
  public let schema: Int
  public let id: UUID
  public let command: String
  public let arguments: [String: String]
  public let deadline: Double
  public init(command: String, arguments: [String: String] = [:], timeout: Double = 10) {
    schema = 1; id = UUID(); self.command = command; self.arguments = arguments
    deadline = Date().timeIntervalSince1970 + timeout
  }
  public func validate(now: Double = Date().timeIntervalSince1970) throws {
    guard schema == 1, command.range(of: #"^[a-z][A-Za-z.]{0,63}$"#, options: .regularExpression) != nil,
      arguments.count <= 16, arguments.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 8192 }),
      deadline.isFinite, deadline >= now, deadline <= now + 31
    else { throw MTVError.code("invalid-or-expired-control-request") }
  }
}

public enum LocalControlJSON {
  public static func encode(_ value: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
      ?? Data(#"{"schema":1,"ok":false,"error":"response-encoding-failed"}"#.utf8)
  }
  public static func failure(_ code: String, id: UUID? = nil) -> Data {
    var value: [String: Any] = ["schema": 1, "ok": false, "error": code]
    if let id { value["id"] = id.uuidString }
    return encode(value)
  }
  /// UI/platform errors can contain signed URLs. Never expose them through logs.
  public static func safeText(_ text: String) -> String {
    var value = String(text.prefix(2048))
    for pattern in [#"(?i)[a-z][a-z0-9+.-]*://[^\s<>\"']+"#, #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
      #"(?i)(?:cookie|authorization|sessdata|bili_jct|DedeUserID(?:__ckMd5)?|__pus|__puus|__kps|__uid|token|password)\s*[:=]\s*[^\s,;]+"#] {
      value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
    }
    return value
  }
}

/// A local, opt-in control channel. There is no IP listener or credential RPC.
public enum LocalControlPaths {
  public static let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MTV/Control", isDirectory: true)
  public static func prepare(_ root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MTVError.code("unsafe-control-directory") }
    defer { close(fd) }
    var node = stat()
    guard fstat(fd, &node) == 0, node.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw MTVError.code("unsafe-control-directory") }
  }
  public static func write(_ data: Data, name: String, root: URL) throws {
    guard ["state.json", "events.jsonl"].contains(name) else { throw MTVError.code("invalid-control-file") }
    try prepare(root)
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw MTVError.code("unsafe-control-directory") }
    defer { close(directory) }
    let temporary = ".write-" + UUID().uuidString
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MTVError.code("control-file-write-failed") }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    try LocalControlIO.send(data, to: fd, socket: false)
    guard renameat(directory, temporary, directory, name) == 0 else { throw MTVError.code("control-file-write-failed") }
  }
  public static func writeVisual(_ data: Data, root: URL) throws -> URL {
    guard data.count <= 20_000_000, data.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])) else { throw MTVError.code("invalid-visual-export") }
    try prepare(root)
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw MTVError.code("unsafe-visual-directory") }
    defer { close(directory) }
    let name = UUID().uuidString.lowercased() + ".png"
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MTVError.code("visual-write-failed") }
    defer { close(fd) }
    do { try LocalControlIO.send(data, to: fd, socket: false) }
    catch { _ = unlinkat(directory, name, 0); throw error }
    return root.appendingPathComponent(name)
  }
}

private enum LocalControlIO {
  static let requestLimit = 32768, responseLimit = 512 * 1024
  static func address(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MTVError.code("control-socket-path-too-long") }
    address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }
  static func configure(_ fd: Int32) {
    // Darwin accepts inherit O_NONBLOCK from the listener. A client frame must
    // wait for its bytes with the bounded socket timeout instead of racing EAGAIN.
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    var yes: Int32 = 1, timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
  }
  static func ownPeer(_ fd: Int32) -> Bool {
    var uid: uid_t = 0, gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
  }
  static func frame(from fd: Int32, limit: Int) throws -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.recv(fd, &buffer, buffer.count, 0)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw MTVError.code("incomplete-control-frame") }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= limit else { throw MTVError.code("control-frame-too-large") }
      if let end = data.firstIndex(of: 10) {
        guard data[data.index(after: end)...].allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw MTVError.code("multiple-control-frames") }
        return data[..<end]
      }
    }
  }
  static func send(_ data: Data, to fd: Int32, socket: Bool = true) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = socket ? Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_NOSIGNAL)
          : Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MTVError.code("control-write-failed") }
        offset += count
      }
    }
  }
}

public final class LocalControlServer: @unchecked Sendable {
  public typealias Handler = @Sendable (LocalControlRequest) async -> Data
  private let root: URL
  private let queue = DispatchQueue(label: "local.mtv.control.accept")
  private let clients = DispatchQueue(label: "local.mtv.control.clients", attributes: .concurrent)
  private let slots = DispatchSemaphore(value: 4)
  private var source: DispatchSourceRead?
  public init(root: URL = LocalControlPaths.root) { self.root = root }
  public func start(handler: @escaping Handler) throws {
    guard source == nil else { throw MTVError.code("control-already-started") }
    try LocalControlPaths.prepare(root)
    let path = root.appendingPathComponent("control.sock").path
    var old = stat()
    if lstat(path, &old) == 0 {
      guard old.st_uid == getuid(), old.st_mode & S_IFMT == S_IFSOCK else { throw MTVError.code("unsafe-control-endpoint") }
      let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      guard probe >= 0 else { throw MTVError.code("control-socket-failed") }
      defer { close(probe) }
      _ = fcntl(probe, F_SETFL, O_NONBLOCK)
      var address = try LocalControlIO.address(path)
      let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      let failure = errno
      guard connected < 0 && failure == ECONNREFUSED else { throw MTVError.code("control-endpoint-in-use") }
      guard unlink(path) == 0 else { throw MTVError.code("control-stale-endpoint-failed") }
    } else if errno != ENOENT { throw MTVError.code("unsafe-control-endpoint") }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MTVError.code("control-socket-failed") }
    do {
      var address = try LocalControlIO.address(path)
      let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      guard bound == 0 else { throw MTVError.code("control-bind-failed") }
      guard chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else { throw MTVError.code("control-listen-failed") }
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      var endpoint = stat(); guard lstat(path, &endpoint) == 0 else { throw MTVError.code("control-endpoint-lost") }
      let inode = endpoint.st_ino
      let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      listener.setEventHandler { [weak self] in
        guard let self else { return }
        while true {
          let client = Darwin.accept(fd, nil, nil)
          if client < 0 { return }
          guard self.slots.wait(timeout: .now()) == .success else { close(client); continue }
          self.clients.async {
            defer { close(client); self.slots.signal() }
            LocalControlIO.configure(client)
            guard LocalControlIO.ownPeer(client) else { return }
            var requestID: UUID?
            var stage = "frame"
            do {
              let data = try LocalControlIO.frame(from: client, limit: LocalControlIO.requestLimit)
              stage = "decode"
              let request = try JSONDecoder().decode(LocalControlRequest.self, from: data)
              requestID = request.id; stage = "validation"; try request.validate()
              stage = "handler"
              let finished = DispatchSemaphore(value: 0)
              let result = ControlResultBox()
              let task = Task { result.set(await handler(request)); finished.signal() }
              guard finished.wait(timeout: .now() + 10) == .success else {
                task.cancel(); throw MTVError.code("control-handler-timeout")
              }
              let reply = result.get()
              stage = "response"
              guard reply.count <= LocalControlIO.responseLimit - 1 else { throw MTVError.code("control-response-too-large") }
              try LocalControlIO.send(reply + Data([10]), to: client)
            } catch {
              try? LocalControlIO.send(LocalControlJSON.failure("control-request-rejected-" + stage, id: requestID) + Data([10]), to: client)
            }
          }
        }
      }
      listener.setCancelHandler {
        close(fd)
        var node = stat()
        if lstat(path, &node) == 0, node.st_uid == getuid(), node.st_ino == inode { _ = unlink(path) }
      }
      source = listener; listener.resume()
    } catch { close(fd); throw error }
  }
  public func stop() { source?.cancel(); source = nil }
  deinit { source?.cancel() }
}

private final class ControlResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Data()
  func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; value = data }
  func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

public enum LocalControlClient {
  public static func send(_ request: LocalControlRequest, root: URL = LocalControlPaths.root) throws -> Data {
    let path = root.appendingPathComponent("control.sock").path
    var directory = stat(), node = stat()
    guard lstat(root.path, &directory) == 0, directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR,
      directory.st_mode & 0o077 == 0, lstat(path, &node) == 0, node.st_uid == getuid(), node.st_mode & S_IFMT == S_IFSOCK,
      node.st_mode & 0o077 == 0 else { throw MTVError.code("control-not-running-or-unsafe") }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MTVError.code("control-socket-failed") }
    defer { close(fd) }; LocalControlIO.configure(fd)
    var address = try LocalControlIO.address(path)
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0, LocalControlIO.ownPeer(fd) else { throw MTVError.code("control-connection-rejected") }
    try LocalControlIO.send(JSONEncoder().encode(request) + Data([10]), to: fd)
    let data = try LocalControlIO.frame(from: fd, limit: LocalControlIO.responseLimit)
    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MTVError.code("invalid-control-response") }
    if reply["id"] == nil, reply["ok"] as? Bool == false, let code = reply["error"] as? String,
      code.range(of: #"^control-request-rejected-[a-z-]{1,20}$"#, options: .regularExpression) != nil {
      throw MTVError.message(code)
    }
    guard reply["id"] as? String == request.id.uuidString else { throw MTVError.code("control-response-id-mismatch") }
    return data
  }
}

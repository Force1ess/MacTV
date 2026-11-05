import Foundation
import Network
import MTVCore

protocol LoopbackByteSource: AnyObject, Sendable {
  var length: Int { get }
  var mime: String { get }
  var maximumReadBytes: Int { get }
  func readSize(offset: Int, remaining: Int) -> Int
  func read(offset: Int, count: Int, consumer: UUID) async throws -> Data
  func releaseConsumer(_ consumer: UUID)
}
extension LoopbackByteSource {
  func readSize(offset: Int, remaining: Int) -> Int { min(maximumReadBytes, remaining) }
}

enum LoopbackMediaBody: @unchecked Sendable {
  case data(Data, mime: String)
  case remote(RemoteRangeClient, offset: Int64, length: Int, mime: String)
  case generated(any LoopbackByteSource)
}

/// A single-session, nonce-routed media origin, bound only to IPv4 loopback.
final class LoopbackMediaServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.mtv.preview.loopback-media")
  private let handler: @Sendable (String) throws -> LoopbackMediaBody
  private let rangeChunkSize: Int
  private let rangeDepth: Int
  private let initialRangeDepth: Int?
  private var listener: NWListener?
  private var connections: [UUID: Connection] = [:]
  private var startup: CheckedContinuation<UInt16, Error>?
  private var closed = false
  private var expectedHost = ""
  private final class Connection {
    let network: NWConnection
    var header = Data()
    var task: Task<Void, Never>?
    init(_ network: NWConnection) { self.network = network }
  }
  init(rangeChunkSize: Int = 1_048_576, rangeDepth: Int = 2, initialRangeDepth: Int? = nil,
    handler: @escaping @Sendable (String) throws -> LoopbackMediaBody) {
    self.rangeChunkSize = rangeChunkSize; self.rangeDepth = rangeDepth; self.initialRangeDepth = initialRangeDepth; self.handler = handler
  }
  func start() async throws -> UInt16 {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          guard !closed, listener == nil else { continuation.resume(throwing: CancellationError()); return }
          do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener; startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
              guard let self else { return }
              switch state {
              case .ready:
                guard let port = self.listener?.port?.rawValue else { return }
                self.expectedHost = "127.0.0.1:\(port)"; self.startup?.resume(returning: port); self.startup = nil
              case .failed(let error): self.startup?.resume(throwing: error); self.startup = nil; self.cancel()
              default: break
              }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
          } catch { continuation.resume(throwing: error) }
        }
      }
    }, onCancel: { self.cancel() })
  }
  func cancel() {
    queue.async { [self] in
      guard !closed else { return }; closed = true
      startup?.resume(throwing: CancellationError()); startup = nil
      listener?.cancel(); listener = nil
      for connection in connections.values { connection.task?.cancel(); connection.network.cancel() }
      connections.removeAll()
    }
  }
  private func accept(_ network: NWConnection) {
    guard !closed, connections.count < 8 else { network.cancel(); return }
    let id = UUID(); let connection = Connection(network); connections[id] = connection
    network.stateUpdateHandler = { [weak self, weak connection] state in
      switch state {
      case .failed, .cancelled:
        connection?.task?.cancel(); self?.connections.removeValue(forKey: id)
      default: break
      }
    }
    network.start(queue: queue); receive(id, connection)
    queue.asyncAfter(deadline: .now() + 5) { [weak connection] in
      if connection?.task == nil { connection?.network.cancel() }
    }
  }
  private func receive(_ id: UUID, _ connection: Connection) {
    connection.network.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, complete, error in
      guard let self, let connection else { return }
      if let data { connection.header.append(data) }
      guard connection.header.count <= 16_384, error == nil else { connection.network.cancel(); return }
      if connection.header.range(of: Data([13, 10, 13, 10])) != nil {
        do {
          let request = try self.parse(connection.header)
          let body = try self.handler(request.path)
          connection.task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do { try await self.respond(connection.network, body: body, range: request.range, consumer: id) }
            catch { connection.network.cancel() }
            self.queue.async { [weak self] in self?.connections.removeValue(forKey: id) }
          }
          if case .data = body {} else {
            // A generated read can be parked on the player's flow budget. Keep
            // observing the peer so a canceled HTTP client releases that wait.
            // This private origin serves single GETs and never pipelined bodies.
            connection.network.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak connection] data, _, complete, error in
              if complete || error != nil || data?.isEmpty == false {
                connection?.task?.cancel(); connection?.network.cancel()
              }
            }
          }
        } catch {
          connection.network.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.network.cancel() })
        }
      } else if complete { connection.network.cancel() }
      else { self.receive(id, connection) }
    }
  }
  private func parse(_ data: Data) throws -> (path: String, range: String?) {
    guard let string = String(data: data, encoding: .ascii), string.hasSuffix("\r\n\r\n") else { throw MTVError.message("无效内部HTTP请求") }
    let lines = string.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard first.count == 3, first[0] == "GET", ["HTTP/1.1", "HTTP/1.0"].contains(first[2]),
      first[1].hasPrefix("/"), first[1].utf8.count <= 256,
      first[1].unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }),
      !first[1].contains("%"), !first[1].contains("?"), !first[1].contains("..") else { throw MTVError.message("内部HTTP请求范围无效") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let split = line.firstIndex(of: ":") else { throw MTVError.message("内部HTTP头无效") }
      let name = line[..<split].lowercased()
      guard headers[name] == nil else { throw MTVError.message("重复内部HTTP头") }
      headers[name] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["host"] == expectedHost, headers["origin"] == nil, headers["authorization"] == nil,
      headers["cookie"] == nil, headers["transfer-encoding"] == nil,
      headers["content-length"] == nil || headers["content-length"] == "0" else { throw MTVError.message("内部HTTP来源不符") }
    return (String(first[1]), headers["range"])
  }
  private func send(_ connection: NWConnection, _ data: Data) async throws {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }
  private func respond(_ connection: NWConnection, body: LoopbackMediaBody, range: String?, consumer: UUID) async throws {
    defer { if case .generated(let source) = body { source.releaseConsumer(consumer) } }
    let length: Int; let mime: String
    switch body {
    case .data(let data, let type): length = data.count; mime = type
    case .remote(_, _, let count, let type): length = count; mime = type
    case .generated(let source):
      guard (1...1_048_576).contains(source.maximumReadBytes) else { throw MTVError.message("内部媒体读取上限无效") }
      length = source.length; mime = source.mime
    }
    guard length > 0 else { throw MTVError.message("空内部资源") }
    var begin = 0; var end = length - 1
    if let range {
      guard range.hasPrefix("bytes="), !range.contains(",") else { throw MTVError.message("内部范围无效") }
      let values = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
      guard values.count == 2, !values[0].isEmpty, values[0].allSatisfy(\.isNumber),
        let start = Int(values[0]), start >= 0, start < length else { throw MTVError.message("内部范围起点无效") }
      begin = start
      if !values[1].isEmpty {
        guard values[1].allSatisfy(\.isNumber), let last = Int(values[1]), last >= start else { throw MTVError.message("内部范围终点无效") }
        end = min(last, end)
      }
    }
    var header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(mime)\r\nContent-Length: \(end - begin + 1)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
    if range != nil { header += "Content-Range: bytes \(begin)-\(end)/\(length)\r\n" }
    header += "\r\n"
    try await send(connection, Data(header.utf8))
    switch body {
    case .data(let data, _): try await send(connection, Data(data[begin...end]))
    case .remote(let client, let offset, _, _):
      try await OrderedRangePump.stream(start: begin, length: end - begin + 1,
        chunkSize: rangeChunkSize, depth: rangeDepth, initialDepth: initialRangeDepth,
        open: { position, count in client.stream(offset: offset + Int64(position), count: count) },
        send: { [self] data in try await send(connection, data) })
    case .generated(let source):
      var position = begin
      while position <= end {
        try Task.checkCancellation()
        let count = source.readSize(offset: position, remaining: end - position + 1)
        guard count > 0, count <= source.maximumReadBytes, count <= end - position + 1 else {
          throw MTVError.message("内部生成媒体分块大小无效")
        }
        let data = try await source.read(offset: position, count: count, consumer: consumer)
        try Task.checkCancellation()
        guard data.count == count else { throw MTVError.message("内部生成媒体片段不完整") }
        try await send(connection, data); position += count
      }
    }
    connection.cancel()
  }
}

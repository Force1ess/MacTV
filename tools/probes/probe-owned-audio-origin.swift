// Isolated experiment, not part of the app. Fixed generated fixture only.
// Reuse the app's existing LoopbackMediaServer if a production bridge is chosen.
import Foundation
import Network

final class OwnedAudioOrigin: @unchecked Sendable {
  private let source: OwnedAudioRangeSource
  private let queue = DispatchQueue(label: "mtv.owned-audio-origin")
  private let listener: NWListener
  private let path = "/" + UUID().uuidString.lowercased() + "/audio.wav"
  private var host = ""
  private var connections: [UUID: NWConnection] = [:]
  private var reads = 0, maximumReadFrames = 0, servedBytes = 0
  private var requestOffsets: [Int] = []
  private let throttled: Bool
  private var clockFrame: Int64
  private var clockInput = Data()
  private var clockUpdates = 0
  private var seekSignals = 0
  private var seekReadAllowance: [ObjectIdentifier: Int] = [:]
  private var pending: [ObjectIdentifier: (NWConnection, Int, Int)] = [:]
  private var closed = false
  private let length: Int
  private let stride: Int
  private let floating: Bool
  private let header: Data
  init(source: OwnedAudioRangeSource, longVirtualTimeline: Bool = false, floating: Bool = false,
    throttled: Bool = false, start: Double = 11.5) throws {
    self.source = source
    self.throttled = throttled; clockFrame = Int64((start * 48000).rounded())
    self.floating = floating; stride = floating ? 4 : 2
    // Stress only: repeat the owned chirp in a virtual two-hour WAV. No long
    // media file is created; this does not test a real long codec/index.
    let stride = floating ? 4 : 2
    let pcmBytes = (longVirtualTimeline ? 7200 : 45) * 48000 * stride
    let length = 44 + pcmBytes; self.length = length
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters, on: .any)
    var wav = Data()
    func text(_ value: String) { wav.append(Data(value.utf8)) }
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) } }
    text("RIFF"); u32(UInt32(length - 8)); text("WAVEfmt "); u32(16)
    u16(floating ? 3 : 1); u16(1); u32(48000); u32(UInt32(48000 * stride)); u16(UInt16(stride)); u16(floating ? 32 : 16)
    text("data"); u32(UInt32(pcmBytes)); header = wav
  }
  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        var completed = false
        listener.stateUpdateHandler = { [weak self] state in
          guard let self, !completed else { return }
          switch state {
          case .ready:
            guard let port = self.listener.port?.rawValue else { return }
            self.host = "127.0.0.1:\(port)"; completed = true
            continuation.resume(returning: URL(string: "http://\(self.host)\(self.path)")!)
          case .failed(let error): completed = true; continuation.resume(throwing: error)
          default: break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
      }
    }
  }
  private func accept(_ connection: NWConnection) {
    guard !closed, connections.count < 4 else { connection.cancel(); return }
    let id = UUID(); connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      switch state {
      case .failed, .cancelled:
        self?.connections.removeValue(forKey: id)
        if let connection {
          self?.pending.removeValue(forKey: ObjectIdentifier(connection))
          self?.seekReadAllowance.removeValue(forKey: ObjectIdentifier(connection))
        }
      default: break
      }
    }
    connection.start(queue: queue); receive(connection, accumulated: Data())
    queue.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
  }
  private func receive(_ connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
      guard let self, !self.closed, error == nil else { connection.cancel(); return }
      var request = accumulated; if let data { request.append(data) }
      guard request.count <= 16384 else { connection.cancel(); return }
      if request.range(of: Data([13, 10, 13, 10])) != nil {
        do {
          let (first, last, partial) = try self.parse(request)
          if self.requestOffsets.count < 32 { self.requestOffsets.append(first) }
          var response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: audio/wav\r\nContent-Length: \(last - first + 1)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
          if partial { response += "Content-Range: bytes \(first)-\(last)/\(self.length)\r\n" }
          response += "\r\n"
          connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            if error == nil { self?.send(connection, first: first, last: last) } else { connection.cancel() }
          })
        } catch { connection.cancel() }
      } else if complete { connection.cancel() }
      else { self.receive(connection, accumulated: request) }
    }
  }
  private func parse(_ data: Data) throws -> (Int, Int, Bool) {
    func bad() -> NSError { NSError(domain: "OwnedAudioOriginRequest", code: 1) }
    guard let string = String(data: data, encoding: .ascii), string.hasSuffix("\r\n\r\n") else { throw bad() }
    let lines = string.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[0] == "GET", parts[1] == path,
      ["HTTP/1.1", "HTTP/1.0"].contains(parts[2]) else { throw bad() }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { throw bad() }
      let key = line[..<colon].lowercased()
      guard headers[key] == nil else { throw bad() }
      headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["host"] == host, headers["origin"] == nil, headers["cookie"] == nil,
      headers["authorization"] == nil, headers["transfer-encoding"] == nil,
      headers["content-length"] == nil || headers["content-length"] == "0" else { throw bad() }
    guard let range = headers["range"] else { return (0, length - 1, false) }
    guard range.hasPrefix("bytes="), !range.contains(",") else { throw bad() }
    let limits = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard limits.count == 2, !limits[0].isEmpty, limits[0].allSatisfy({ $0 >= "0" && $0 <= "9" }),
      let first = Int(limits[0]), first >= 0, first < length else { throw bad() }
    let last: Int
    if limits[1].isEmpty { last = length - 1 }
    else {
      guard limits[1].allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(limits[1]), value >= first else { throw bad() }
      last = min(length - 1, value)
    }
    return (first, last, true)
  }
  private func send(_ connection: NWConnection, first: Int, last: Int) {
    guard !closed else { connection.cancel(); return }
    switch connection.state { case .failed, .cancelled: return; default: break }
    guard first <= last else { connection.cancel(); return }
    let normalLimit = throttled ? min(length, 44 + Int(clockFrame + 3 * 48000) * stride) : length
    let key = ObjectIdentifier(connection)
    let allowance = first >= normalLimit ? (seekReadAllowance[key] ?? 0) : 0
    // A seek can be waiting on the old synchronous slave read. Let that read
    // finish one bounded chunk so VLC can process the seek, even backwards.
    let limit = allowance > 0 ? min(length, first + allowance) : normalLimit
    if first >= limit {
      pending[ObjectIdentifier(connection)] = (connection, first, last); return
    }
    do {
      let chunk: Data
      if first < 44 { chunk = header.subdata(in: first..<min(44, last + 1)) }
      else {
        let offset = first - 44, count = min(65536, last - first + 1, limit - first)
        let frame = (offset / stride) % (45 * 48000), skip = offset % stride, frames = (skip + count + stride - 1) / stride
        let headFrames = min(frames, 45 * 48000 - frame)
        var pcm = try source.read(first: Int64(frame), frames: Int64(headFrames), floating: floating).pcm
        reads += 1; maximumReadFrames = max(maximumReadFrames, headFrames)
        if headFrames < frames {
          pcm.append(try source.read(first: 0, frames: Int64(frames - headFrames), floating: floating).pcm)
          reads += 1; maximumReadFrames = max(maximumReadFrames, frames - headFrames)
        }
        chunk = pcm.subdata(in: skip..<(skip + count))
      }
      servedBytes += chunk.count
      if allowance > 0 { seekReadAllowance[key] = max(0, allowance - chunk.count) }
      connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
        if error == nil { self?.send(connection, first: first + chunk.count, last: last) }
        else { connection.cancel() }
      })
    } catch { connection.cancel() }
  }
  func receiveClock(_ data: Data) {
    queue.async { [self] in
      guard !closed else { return }
      clockInput.append(data)
      guard clockInput.count <= 8192 else { clockInput.removeAll(); return }
      while let newline = clockInput.firstIndex(of: 10) {
        let line = String(decoding: clockInput[..<newline], as: UTF8.self)
        clockInput.removeSubrange(...newline)
        if line == "MTV_STOP" { close(); return }
        let parts = line.split(separator: " ")
        // Ignore the uninitialized zero clock in this nonzero-start experiment.
        guard parts.count == 2, ["MTV_CLOCK", "MTV_SEEK"].contains(parts[0]),
          let ms = Int64(parts[1]), ms > 0, ms <= 45000 else { continue }
        if parts[0] == "MTV_SEEK" {
          seekSignals += 1
          for connection in connections.values { seekReadAllowance[ObjectIdentifier(connection)] = 65536 }
        }
        clockFrame = ms * 48; clockUpdates += 1
        let waiting = Array(pending.values); pending.removeAll()
        for (connection, first, last) in waiting { send(connection, first: first, last: last) }
      }
    }
  }
  private func close() {
    closed = true; listener.cancel()
    for connection in connections.values { connection.cancel() }
    pending.removeAll(); seekReadAllowance.removeAll()
  }
  func stop() -> [String: Any] {
    queue.sync {
      close()
      return ["decodeReads": reads, "maximumReadFrames": maximumReadFrames, "servedBytes": servedBytes,
        "virtualWAVBytes": length,
        "format": floating ? "F32LE" : "S16LE",
        "clockFlowControl": throttled, "clockUpdates": clockUpdates, "readAheadSeconds": throttled ? 3 : -1,
        "seekSignals": seekSignals,
        "requestOffsets": requestOffsets, "wholeTrackPCMCache": false,
        "maximumSendChunkBytes": 65536, "physicalAudioOutputVerified": false]
    }
  }
}

@main struct OwnedAudioOriginProbe {
  static func main() async throws {
    let args = CommandLine.arguments, home = FileManager.default.homeDirectoryForCurrentUser
    guard args.count == 3, ["11.5", "23.5"].contains(args[1]) else { throw NSError(domain: "OwnedAudioOriginArguments", code: 1) }
    let source = try await OwnedAudioRangeSource()
    let throttled = ProcessInfo.processInfo.environment["MTV_OWNED_AUDIO_THROTTLE"] == "1"
    let server = try OwnedAudioOrigin(source: source,
      longVirtualTimeline: ProcessInfo.processInfo.environment["MTV_OWNED_AUDIO_LONG_ORIGIN"] == "1",
      floating: ProcessInfo.processInfo.environment["MTV_OWNED_AUDIO_FLOAT_ORIGIN"] == "1",
      throttled: throttled, start: Double(args[1])!)
    let url = try await server.start()
    let process = Process(); process.executableURL = home.appendingPathComponent("Developer/MTV/.build/ProbeOwnedVLCAudio")
    process.arguments = [home.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4").path, args[1], args[2], "avformat"]
    var environment = ProcessInfo.processInfo.environment
    environment["MTV_OWNED_AUDIO_COMPAT"] = "1"; environment["MTV_OWNED_AUDIO_ORIGIN"] = url.absoluteString
    let clockPipe = Pipe()
    if throttled {
      environment["MTV_OWNED_AUDIO_CLOCK_STREAM"] = "1"
      process.standardOutput = clockPipe
      clockPipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil } else { server?.receiveClock(data) }
      }
    }
    process.environment = environment
    do { try process.run(); process.waitUntilExit() }
    catch { clockPipe.fileHandleForReading.readabilityHandler = nil; _ = server.stop(); throw error }
    clockPipe.fileHandleForReading.readabilityHandler = nil
    let statistics = server.stop()
    print(String(decoding: try JSONSerialization.data(withJSONObject: statistics, options: [.sortedKeys]), as: UTF8.self))
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw NSError(domain: "OwnedAudioOriginChild", code: Int(process.terminationStatus)) }
  }
}

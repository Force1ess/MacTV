import Foundation
import MTVCore

/// One origin and scoped decoder lifetime per playback.
final class SystemAudioWaveSession: @unchecked Sendable {
  let url: URL
  private let source: SystemAudioWaveSource
  private let server: LoopbackMediaServer
  private init(url: URL, source: SystemAudioWaveSource, server: LoopbackMediaServer) {
    self.url = url; self.source = source; self.server = server
  }
  static func prepareOwnedFixture(start: Double) async throws -> SystemAudioWaveSession {
    let source = try await SystemAudioWaveSource.prepareOwnedFixture(start: start)
    return try await serve(source)
  }
  static func prepare(file: URL, start: Double, access: ScopedFileAccess) async throws -> SystemAudioWaveSession {
    let source = try await SystemAudioWaveSource.prepare(file: file, start: start, access: access, requireEdits: true)
    return try await serve(source)
  }
  private static func serve(_ source: SystemAudioWaveSource) async throws -> SystemAudioWaveSession {
    let path = "/" + UUID().uuidString.lowercased() + "/audio.wav"
    let server = LoopbackMediaServer { candidate in
      guard candidate == path else { throw MTVError.message("系统音轨路径未授权") }
      return .generated(source)
    }
    do {
      let port = try await server.start()
      try Task.checkCancellation()
      return SystemAudioWaveSession(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, source: source, server: server)
    } catch { source.cancel(); server.cancel(); throw error }
  }
  func update(seconds: Double) async {
    guard seconds.isFinite, seconds >= 0, seconds <= Double(source.wave.frames) / Double(source.wave.sampleRate) else { return }
    await source.budget.update(frame: Int64((seconds * Double(source.wave.sampleRate)).rounded()))
  }
  func seek(seconds: Double) async {
    guard seconds.isFinite, seconds >= 0 else { return }
    let position = min(seconds, Double(source.wave.frames) / Double(source.wave.sampleRate))
    await source.budget.seek(frame: Int64((position * Double(source.wave.sampleRate)).rounded()))
  }
  func cancel() { source.cancel(); server.cancel() }
  var failureMessage: String? { source.failureMessage }
  func pendingReadsForTesting() async -> Int { await source.budget.pendingCount }
  deinit { cancel() }
}

import Darwin
import Foundation

/// Fixed-command, pipe-only conversion by the bundled minimal FFmpeg executable.
/// Runs on LocalSubtitleReader's actor, never on the UI actor.
public struct WebVTTConverter: Sendable {
  public let executable: URL
  public init(executable: URL) { self.executable = executable }
  public static var bundled: Self? {
    guard let file = Bundle.main.resourceURL?.appendingPathComponent("SubtitleTool/ffmpeg"),
      FileManager.default.isExecutableFile(atPath: file.path) else { return nil }
    return Self(executable: file)
  }
  public func convert(_ input: Data) throws -> Data {
    try Task.checkCancellation()
    guard !input.isEmpty, input.count <= LocalSubtitles.maximumBytes, executable.isFileURL,
      FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.featureUnsupported) }
    let process = Process(), source = Pipe(), destination = Pipe()
    process.executableURL = executable
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
    process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-protocol_whitelist", "pipe",
      "-f", "webvtt", "-i", "pipe:0", "-map", "0:s:0", "-c:s", "ass", "-f", "ass", "pipe:1"]
    process.standardInput = source; process.standardOutput = destination; process.standardError = FileHandle.nullDevice
    // A failed child must not deliver SIGPIPE to the main application.
    guard fcntl(source.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CocoaError(.fileWriteUnknown) }
    try process.run()
    try? source.fileHandleForReading.close(); try? destination.fileHandleForWriting.close()
    let writer = DispatchGroup()
    writer.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { try? source.fileHandleForWriting.close(); writer.leave() }
      try? source.fileHandleForWriting.write(contentsOf: input)
    }
    let deadline = DispatchWorkItem {
      if process.isRunning { process.terminate() }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
    var output = Data(), failed = false
    do {
      while let chunk = try destination.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        if Task.isCancelled || output.count + chunk.count > 12_000_000 { failed = true; process.terminate(); break }
        output.append(chunk)
      }
    } catch { failed = true; if process.isRunning { process.terminate() } }
    try? destination.fileHandleForReading.close()
    process.waitUntilExit(); deadline.cancel()
    _ = writer.wait(timeout: .now() + 2)
    try Task.checkCancellation()
    guard !failed, process.terminationReason == .exit, process.terminationStatus == 0,
      String(decoding: output.prefix(4096), as: UTF8.self).contains("[Events]"),
      output.range(of: Data("Dialogue:".utf8)) != nil else { throw MTVError.message("WebVTT 字幕转换失败，原播放未改变。") }
    return output
  }
}

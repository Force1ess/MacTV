import Foundation
import Testing
@testable import MTVCore

private let subtitleTestTool = TestProject.root.appendingPathComponent("vendor/SubtitleTool/ffmpeg")

struct WebVTTConverterTests {
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: subtitleTestTool.path), "Requires the explicit minimal converter build"))
  func matureConverterPreservesCueTimeAndUnicodeInOwnedASSCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = Data("WEBVTT\n\n00:00.000 --> 00:44.500\nMTV WebVTT 外挂中文字幕\n".utf8)
    let media = root.appendingPathComponent("Film.mp4"), caption = root.appendingPathComponent("Film.vtt")
    try Data().write(to: media); try source.write(to: caption)
    let candidate = try LocalSubtitles.discover(for: media, access: .within(root)).candidates[0]
    let prepared = try LocalSubtitles.prepare(candidate, access: .within(root), storage: root.appendingPathComponent("copies"), converter: WebVTTConverter(executable: subtitleTestTool))
    let text = try String(contentsOf: prepared.url, encoding: .utf8)
    #expect(prepared.url.pathExtension == "ass" && prepared.source.filename == "Film.vtt")
    #expect(text.contains("0:00:00.00,0:00:44.50") && text.contains("MTV WebVTT 外挂中文字幕"))
    #expect(try Data(contentsOf: caption) == source)
  }
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: subtitleTestTool.path), "Requires the explicit minimal converter build"))
  func malformedPipeInputCannotKillHostOrReturnSuccessfulSubtitle() {
    let converter = WebVTTConverter(executable: subtitleTestTool)
    #expect(throws: (any Error).self) { try converter.convert(Data(repeating: 120, count: LocalSubtitles.maximumBytes)) }
    #expect(throws: (any Error).self) { try converter.convert(Data()) }
  }
}

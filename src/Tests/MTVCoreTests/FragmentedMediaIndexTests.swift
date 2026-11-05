import Foundation
import Testing
@testable import MTVCore

struct FragmentedMediaIndexTests {
  func uint(_ value: UInt64, _ width: Int = 4) -> Data { Data((0..<width).map { UInt8((value >> ((width - 1 - $0) * 8)) & 255) }) }
  func box(_ name: String, _ body: Data) -> Data { uint(UInt64(body.count + 8)) + Data(name.utf8) + body }
  func sample(codec: String = "avc1", flags: UInt64 = 0x020000, hierarchical: Bool = false, external: Bool = false) -> Data {
    let movieHeader = box("mvhd", Data(repeating: 0, count: 12) + uint(1000) + uint(10_000))
    let trackHeader = box("tkhd", Data(repeating: 0, count: 20) + uint(10_000))
    let stsd = box("stsd", uint(0) + uint(1) + box(codec, Data()))
    let dref = box("dinf", box("dref", uint(0) + uint(1) + box("url ", external ? uint(0) + Data("file:///unreadable-test\0".utf8) : uint(1))))
    let track = box("trak", trackHeader + box("mdia", box("minf", dref + box("stbl", stsd))))
    let moov = box("moov", movieHeader + track + box("mvex", Data()))
    let fragment = box("moof", box("traf", box("tfhd", uint(flags) + uint(1)))) + box("mdat", Data(repeating: 4, count: 40))
    let entry = uint(UInt64(fragment.count) | (hierarchical ? 0x8000_0000 : 0)) + uint(5000) + uint(0x9000_0000)
    let index = box("sidx", uint(0) + uint(1) + uint(1000) + uint(0) + uint(0) + uint(0, 2) + uint(2, 2) + entry + entry)
    return box("ftyp", Data("isom0000".utf8)) + moov + index + fragment + fragment
  }
  @Test func buildsFiniteLocalPlaylistsAndKeepsOriginalFragmentRanges() throws {
    let original = sample()
    let index = try FragmentedMediaIndex.parse(original, totalLength: Int64(original.count))
    #expect(index.codec == "avc1" && index.duration == 10 && index.segments.count == 2)
    #expect(index.segments[0].offset + Int64(index.segments[0].length) == index.segments[1].offset)
    #expect(index.segments[1].offset + Int64(index.segments[1].length) == Int64(original.count))
    #expect(String(data: index.initialization[8..<12], encoding: .ascii) == "iso6")
    let playlist = try index.playlist(prefix: "/abc-123/v")
    #expect(playlist.contains("#EXT-X-MAP:URI=\"/abc-123/v/init.mp4\""))
    #expect(playlist.contains("#EXTINF:5.000000,"))
    #expect(playlist.contains("/abc-123/v/1.m4s") && playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    #expect(!playlist.contains("https:") && !playlist.contains("Cookie"))
    #expect(throws: (any Error).self) { try index.playlist(prefix: "/abc/v\n#EXT-X-KEY") }
  }
  @Test func rejectsExternalAddressingEncryptionHierarchicalIndexesAndOutOfBounds() throws {
    for data in [sample(codec: "encv"), sample(flags: 1), sample(hierarchical: true), sample(external: true), Data(sample().prefix(32)),
      uint(1) + Data("moov".utf8) + uint(UInt64.max, 8)] {
      #expect(throws: (any Error).self) { try FragmentedMediaIndex.parse(data, totalLength: Int64(data.count)) }
    }
    let original = sample()
    #expect(throws: (any Error).self) { try FragmentedMediaIndex.parse(original, totalLength: 20) }
  }
}

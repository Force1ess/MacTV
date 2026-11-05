import Foundation
import Testing
@testable import MTVCore

struct MatroskaLayoutTests {
  private let prefix:[UInt8] = [0x1a,0x45,0xdf,0xa3,0x8b,0x42,0x82,0x88]+Array("matroska".utf8)+[0x18,0x53,0x80,0x67,0xff]
  @Test func indexesUnknownLengthSegmentWithoutReadingAttachmentBodies() throws {
    let seek:[UInt8] = [0x11,0x4d,0x9b,0x74,0x8e,0x4d,0xbb,0x8b,0x53,0xab,0x84,0x19,0x41,0xa4,0x69,0x53,0xac,0x81,0x40]
    let layout=try #require(MatroskaLayout.inspect(Data(prefix+seek),fileLength:1000))
    #expect(layout.leadingElements.map(\.name)==["EBML","Segment","SeekHead"])
    #expect(layout.seekTargets.first?.name=="Attachments")
    #expect(layout.seekTargets.first?.offset==85)
    let attachment=try #require(MatroskaLayout.elementHeader(Data([0x19,0x41,0xa4,0x69,0x20,0xff,0x00]),offset:85))
    #expect(attachment.size==65280 && attachment.offset==85)
  }
  @Test func rejectsTruncationAndOutOfFileSeekPositions() throws {
    #expect(MatroskaLayout.inspect(Data(prefix.prefix(8)),fileLength:1000)==nil)
    #expect(MatroskaLayout.elementHeader(Data([0]),offset:0)==nil)
    let seek:[UInt8] = [0x11,0x4d,0x9b,0x74,0x95,0x4d,0xbb,0x92,0x53,0xab,0x84,0x19,0x41,0xa4,0x69,0x53,0xac,0x88]+Array(repeating:0xff,count:8)
    let layout=try #require(MatroskaLayout.inspect(Data(prefix+seek),fileLength:1000))
    #expect(layout.seekTargets.isEmpty)
  }
}

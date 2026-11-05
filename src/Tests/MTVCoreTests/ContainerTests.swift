import Foundation
import Testing

@testable import MTVCore

struct ContainerTests {
  private func ebml(_ type: [UInt8]) -> Data {
    Data(
      [0x1a, 0x45, 0xdf, 0xa3, UInt8(0x80 + 3 + type.count), 0x42, 0x82, UInt8(0x80 + type.count)]
        + type)
  }
  @Test func identifiesDocumentTypeRatherThanExtensionOrEmbeddedText() {
    #expect(ContainerInspection.matroskaHeader(ebml(Array("matroska".utf8))))
    #expect(ContainerInspection.matroskaHeader(ebml(Array("matroska".utf8) + [0])))
    #expect(!ContainerInspection.matroskaHeader(ebml(Array("webm".utf8))))
    #expect(!ContainerInspection.matroskaHeader(Data("mp4 data matroska".utf8)))
    #expect(!ContainerInspection.matroskaHeader(ebml(Array("matroska".utf8) + [0, 1])))
  }
  @Test func malformedLengthsAndTruncatedHeadersAreRejected() {
    let good = ebml(Array("matroska".utf8))
    for length in 0..<good.count {
      #expect(!ContainerInspection.matroskaHeader(good.prefix(length)))
    }
    for data in [
      Data([0x1a, 0x45, 0xdf, 0xa3, 0]),
      Data([0x1a, 0x45, 0xdf, 0xa3, 0xff, 0x42, 0x82, 0xff]),
      Data([0x1a, 0x45, 0xdf, 0xa3, 0x84, 0x42, 0x82, 0xff, 0]),
    ] {
      #expect(!ContainerInspection.matroskaHeader(data))
    }
  }
}

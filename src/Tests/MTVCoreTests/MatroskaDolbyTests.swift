import Foundation
import Testing
@testable import MTVCore

struct MatroskaDolbyTests {
  private func element(_ id: [UInt8], _ payload: Data) -> Data {
    precondition(payload.count < 127)
    return Data(id + [0x80 | UInt8(payload.count)]) + payload
  }
  private func file(profile: UInt8 = 5, type: UInt8 = 1, codec: String = "V_MPEGH/ISO/HEVC", rpu: Bool = true) -> Data {
    let header = element([0x1a,0x45,0xdf,0xa3],element([0x42,0x82],Data("matroska".utf8)))
    let configuration = Data([1,0,profile << 1,rpu ? 0x35:0x31]) + Data(repeating:0,count:20)
    let mapping = element([0x41,0xe4],element([0x41,0xe7],Data("dvcC".utf8)) + element([0x41,0xed],configuration))
    let track = element([0xae],element([0x83],Data([type])) + element([0x86],Data(codec.utf8)) + mapping)
    return header + element([0x18,0x53,0x80,0x67],element([0x16,0x54,0xae,0x6b],track))
  }
  @Test func identifiesActualVideoMappingRatherThanFilenameOrLooseText() {
    #expect(ContainerInspection.dolbyVisionProfile(file()) == 5)
    #expect(ContainerInspection.dolbyVisionProfile(file(profile:8)) == 8)
    #expect(ContainerInspection.dolbyVisionProfile(file(type:2)) == nil)
    #expect(ContainerInspection.dolbyVisionProfile(file(codec:"V_MPEG4/ISO/AVC")) == nil)
    #expect(ContainerInspection.dolbyVisionProfile(file(rpu:false)) == nil)
    #expect(ContainerInspection.dolbyVisionProfile(Data("matroska dvcC Dolby Vision Profile5".utf8)) == nil)
  }
  @Test func rejectsTruncatedMetadataAndIgnoresMappingsInsideVideoClusters() {
    let good = file()
    for size in [0,1,4,15,good.count - 1] { #expect(ContainerInspection.dolbyVisionProfile(Data(good.prefix(size))) == nil) }
    let header = element([0x1a,0x45,0xdf,0xa3],element([0x42,0x82],Data("matroska".utf8)))
    let cluster = element([0x1f,0x43,0xb6,0x75],file())
    #expect(ContainerInspection.dolbyVisionProfile(header + element([0x18,0x53,0x80,0x67],cluster)) == nil)
    let unknownSegment = header + Data([0x18,0x53,0x80,0x67,0xff]) + good.dropFirst(header.count + 5)
    #expect(ContainerInspection.dolbyVisionProfile(unknownSegment) == 5)
    // A large later attachment may extend beyond the bounded header read.
    // Completed Tracks remain valid, while truncated Tracks above still fail.
    let attachmentPrefix = Data([0x19,0x41,0xa4,0x69,0x20,0x10,0x00,0x00])
    #expect(ContainerInspection.dolbyVisionProfile(unknownSegment + attachmentPrefix) == 5)
  }
}

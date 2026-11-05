import Testing
@testable import MTVCore

struct VideoPresentationTests {
  @Test func codecOrWideGamutAloneCannotBecomeHDRClaim() {
    let source = VideoSourceSignal(codec: "hvc1", width: 3840, height: 2160, framesPerSecond: 24,
      primaries: "ITU_R_2020", transferFunction: nil, containsHDR: false, dolbyVisionSignaled: false)
    #expect(source.rangeLabel == "SDR 或未标记")
  }
  @Test func explicitTransferAndDolbyMarkersDescribeSourceOnly() {
    for (transfer, label) in [("ITU_R_2100_HLG", "HDR · HLG"), ("SMPTE_ST_2084_PQ", "HDR · PQ")] {
      let source = VideoSourceSignal(codec: "hvc1", width: 640, height: 360, framesPerSecond: 30,
        primaries: "ITU_R_2020", transferFunction: transfer, containsHDR: true, dolbyVisionSignaled: false)
      #expect(source.rangeLabel == label)
    }
    let dolby = VideoSourceSignal(codec: "dvh1", width: 640, height: 360, framesPerSecond: nil,
      primaries: nil, transferFunction: nil, containsHDR: true, dolbyVisionSignaled: true)
    #expect(dolby.rangeLabel == "Dolby Vision 标记")
  }
}

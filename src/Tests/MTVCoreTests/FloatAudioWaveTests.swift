import Foundation
import Testing
@testable import MTVCore

struct FloatAudioWaveTests {
  private func uint(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
    (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
  }
  @Test func smallFloatWaveCarriesRateFramesAndPayloadSize() throws {
    let wave = try FloatAudioWave(sampleRate: 44100, channels: 2, frames: 88200)
    #expect(!wave.usesRF64 && wave.header.count == 58)
    #expect(String(decoding: wave.header.prefix(4), as: UTF8.self) == "RIFF")
    #expect(uint(wave.header, 4, 4) == UInt64(wave.length - 8))
    #expect(uint(wave.header, 20, 2) == 3 && uint(wave.header, 22, 2) == 2)
    #expect(uint(wave.header, 24, 4) == 44100 && uint(wave.header, 32, 2) == 8)
    #expect(uint(wave.header, 46, 4) == 88200 && uint(wave.header, 54, 4) == 705600)
  }
  @Test func largeWaveUses64BitSizesWithoutAllocatingPayload() throws {
    let wave = try FloatAudioWave(sampleRate: 192000, channels: 2, frames: 192000 * 14400)
    #expect(wave.usesRF64 && wave.header.count == 94 && wave.length > Int(UInt32.max))
    #expect(String(decoding: wave.header.prefix(4), as: UTF8.self) == "RF64")
    #expect(uint(wave.header, 4, 4) == UInt64(UInt32.max))
    #expect(uint(wave.header, 20, 8) == UInt64(wave.length - 8))
    #expect(uint(wave.header, 28, 8) == UInt64(wave.frames) * 8)
    #expect(uint(wave.header, 36, 8) == UInt64(wave.frames))
    #expect(uint(wave.header, 90, 4) == UInt64(UInt32.max))
  }
  @Test func bytePlansCoverHeaderUnalignedSamplesAndFinalByte() throws {
    let wave = try FloatAudioWave(sampleRate: 48000, channels: 2, frames: 96000)
    let header = try wave.readPlan(offset: 0, count: 58)
    #expect(header.header == wave.header && header.frameCount == 0)
    let mixed = try wave.readPlan(offset: 56, count: 9)
    #expect(mixed.header.count == 2 && mixed.pcmByteCount == 7 && mixed.firstFrame == 0 && mixed.frameCount == 1)
    let unaligned = try wave.readPlan(offset: 61, count: 14)
    #expect(unaligned.firstFrame == 0 && unaligned.leadingPCMBytes == 3 && unaligned.frameCount == 3)
    let last = try wave.readPlan(offset: wave.length - 1, count: 1)
    #expect(last.firstFrame == 95999 && last.leadingPCMBytes == 7 && last.frameCount == 1)
    let lowRate = try FloatAudioWave(sampleRate: 8000, channels: 1, frames: 80000)
    let plan = try lowRate.readPlan(offset: lowRate.header.count + 3, count: lowRate.maximumReadBytes)
    #expect(plan.frameCount <= 16000)
    #expect(throws: Error.self) { try wave.readPlan(offset: wave.length - 1, count: 2) }
    #expect(throws: Error.self) { try wave.readPlan(offset: Int.max, count: 1) }
    #expect(throws: Error.self) { try wave.readPlan(offset: 0, count: 65537) }
  }
  @Test func unsupportedChannelsAndUnboundedDurationsAreRejected() {
    for value in [(48000, 0, Int64(1)), (48000, 6, 1), (0, 1, 1), (Int.max, 1, 1), (48000, 1, -1), (48000, 2, .max)] {
      #expect(throws: Error.self) { try FloatAudioWave(sampleRate: value.0, channels: value.1, frames: value.2) }
    }
  }
}

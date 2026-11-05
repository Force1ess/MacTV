import Foundation

/// A virtual little-endian Float32 WAVE. It describes bytes, never allocates the
/// audio payload. Mono/stereo only until channel-layout mapping is verified.
public struct FloatAudioWave: Sendable {
  public let sampleRate: Int
  public let channels: Int
  public let frames: Int64
  public let bytesPerFrame: Int
  public let header: Data
  public let length: Int
  public let maximumReadBytes: Int
  public let usesRF64: Bool

  public init(sampleRate: Int, channels: Int, frames: Int64) throws {
    guard (8000...192000).contains(sampleRate), (1...2).contains(channels),
      frames > 0, frames <= Int64(sampleRate) * 86400 else {
      throw MTVError.message("系统音轨的格式或时长暂不支持")
    }
    self.sampleRate = sampleRate; self.channels = channels; self.frames = frames
    bytesPerFrame = channels * 4
    maximumReadBytes = min(65536, sampleRate * 2 * bytesPerFrame - (bytesPerFrame - 1))
    let dataSize = UInt64(frames) * UInt64(bytesPerFrame)
    usesRF64 = dataSize + 50 >= UInt64(UInt32.max)
    let headerSize = usesRF64 ? 94 : 58
    length = Int(dataSize) + headerSize
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u64(_ value: UInt64) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    text(usesRF64 ? "RF64" : "RIFF"); u32(usesRF64 ? .max : UInt32(length - 8)); text("WAVE")
    if usesRF64 {
      text("ds64"); u32(28); u64(UInt64(length - 8)); u64(dataSize); u64(UInt64(frames)); u32(0)
    }
    text("fmt "); u32(18); u16(3); u16(UInt16(channels)); u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * bytesPerFrame)); u16(UInt16(bytesPerFrame)); u16(32); u16(0)
    text("fact"); u32(4); u32(frames >= Int64(UInt32.max) ? .max : UInt32(frames))
    text("data"); u32(usesRF64 ? .max : UInt32(dataSize))
    header = data
  }

  public struct ReadPlan: Sendable {
    public let header: Data
    public let firstFrame: Int64
    public let frameCount: Int
    public let leadingPCMBytes: Int
    public let pcmByteCount: Int
  }
  /// Byte ranges need not be sample-aligned. Decode complete covering frames,
  /// then return only the explicitly requested PCM bytes.
  public func readPlan(offset: Int, count: Int) throws -> ReadPlan {
    guard offset >= 0, count > 0, count <= maximumReadBytes, offset < length, count <= length - offset else {
      throw MTVError.message("系统音轨读取范围无效")
    }
    let headerEnd = min(header.count, offset + count)
    let prefix = offset < header.count ? header.subdata(in: offset..<headerEnd) : Data()
    let pcmCount = count - prefix.count, pcmOffset = max(0, offset - header.count)
    let leading = pcmOffset % bytesPerFrame
    return ReadPlan(header: prefix, firstFrame: Int64(pcmOffset / bytesPerFrame),
      frameCount: pcmCount == 0 ? 0 : (leading + pcmCount + bytesPerFrame - 1) / bytesPerFrame,
      leadingPCMBytes: leading, pcmByteCount: pcmCount)
  }
}

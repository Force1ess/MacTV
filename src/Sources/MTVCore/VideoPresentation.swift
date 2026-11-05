import Foundation

public enum VideoRangeChoice: String, CaseIterable, Codable, Sendable {
  case automatic, standard, high
  public var title: String {
    switch self {
    case .automatic: return "自动"
    case .standard: return "兼容 SDR"
    case .high: return "允许完整 HDR"
    }
  }
  public var detail: String {
    switch self {
    case .automatic: return "由系统匹配片源与显示能力"
    case .standard: return "由系统将 HDR 映射到标准动态范围"
    case .high: return "允许 HDR 片源使用显示器可用的动态范围"
    }
  }
}

public struct VideoSourceSignal: Codable, Equatable, Sendable {
  public let codec: String
  public let width: Int
  public let height: Int
  public let framesPerSecond: Double?
  public let primaries: String?
  public let transferFunction: String?
  public let containsHDR: Bool
  public let dolbyVisionSignaled: Bool
  public init(codec: String, width: Int, height: Int, framesPerSecond: Double?, primaries: String?,
    transferFunction: String?, containsHDR: Bool, dolbyVisionSignaled: Bool) {
    self.codec = codec; self.width = width; self.height = height
    self.framesPerSecond = framesPerSecond; self.primaries = primaries
    self.transferFunction = transferFunction; self.containsHDR = containsHDR
    self.dolbyVisionSignaled = dolbyVisionSignaled
  }
  public var rangeLabel: String {
    if dolbyVisionSignaled { return "Dolby Vision 标记" }
    if transferFunction == "SMPTE_ST_2084_PQ" { return "HDR · PQ" }
    if transferFunction == "ITU_R_2100_HLG" { return "HDR · HLG" }
    return containsHDR ? "HDR 标记" : "SDR 或未标记"
  }
}

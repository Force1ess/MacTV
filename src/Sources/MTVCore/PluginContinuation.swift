import Foundation

public struct PluginContinuation: Codable {
  public let currentReference: String
  public let collectionReference: String
  public let label: String
  public let next: MediaItem?
  enum CodingKeys: String, CodingKey { case currentReference, collectionReference, label, next }
  public init(currentReference: String, collectionReference: String, label: String, next: MediaItem?) {
    self.currentReference = currentReference; self.collectionReference = collectionReference; self.label = label; self.next = next
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard values.contains(.next) else { throw MTVError.message("模块未明确声明后续内容") }
    currentReference = try values.decode(String.self, forKey: .currentReference)
    collectionReference = try values.decode(String.self, forKey: .collectionReference)
    label = try values.decode(String.self, forKey: .label)
    next = try values.decodeIfPresent(MediaItem.self, forKey: .next)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(currentReference, forKey: .currentReference); try values.encode(collectionReference, forKey: .collectionReference)
    try values.encode(label, forKey: .label); try values.encode(next, forKey: .next)
  }
  public func validated(manifest: PluginManifest, currentID: String, expectedCurrent: String? = nil, expectedCollection: String? = nil) throws -> Self {
    try manifest.validate()
    func opaque(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.count <= 512 && !value.contains("://") && !value.lowercased().hasPrefix("file:")
        && !value.hasPrefix("/") && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    guard manifest.capabilities.contains("continuation"), manifest.capabilities.contains("resolve"), manifest.capabilities.contains("folders"),
      opaque(currentReference), opaque(collectionReference), !label.isEmpty, label.count <= 24,
      label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
      expectedCurrent.map({ $0 == currentReference }) ?? true,
      expectedCollection.map({ $0 == collectionReference }) ?? true else { throw MTVError.message("模块连续播放引用或授权不匹配") }
    var target: MediaItem?
    if let next {
      guard next.url == nil, !next.isFolder, !next.isLibraryCollection, next.collectionReference == nil,
        opaque(next.id), next.id != currentID, let reference = next.reference, opaque(reference), reference != currentReference else {
        throw MTVError.message("后续内容必须是不同的稳定引用，不能携带播放地址")
      }
      target = try PluginContentValidator.normalize([next], manifest: manifest).first
    }
    return Self(currentReference: currentReference, collectionReference: collectionReference, label: label, next: target)
  }
  public func plan(currentID: String, message: String = "") -> EpisodeContinuationPlan? {
    guard let next else { return nil }
    return EpisodeContinuationPlan(currentID: currentID, label: label, message: message, candidates: [next], limited: false)
  }
}

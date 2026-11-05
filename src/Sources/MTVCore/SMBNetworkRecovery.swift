import Foundation

public struct SMBNetworkRecovery {
  public enum Action: Equatable {
    case none
    case offline(UUID)
    case reconnect(UUID)
  }
  private var reachable: Bool?
  private var profile: SMBProfile?
  private var lost = false
  private var attempted = false
  private var blocked = false
  public init() {}
  public mutating func activate(_ profile: SMBProfile) {
    self.profile = profile
    lost = false
    attempted = false
    blocked = false
  }
  public mutating func deactivate() {
    profile = nil
    lost = false
    attempted = false
    blocked = false
  }
  public mutating func failed() { blocked = true }
  public mutating func update(reachable next: Bool) -> Action {
    guard reachable != nil else {
      reachable = next
      return .none
    }
    guard reachable != next else { return .none }
    reachable = next
    guard let profile else { return .none }
    guard profile.allowsAutomaticReconnect else { return .none }
    if !next {
      lost = true
      attempted = false
      return .offline(profile.id)
    }
    guard lost, !attempted, !blocked, profile.allowsAutomaticReconnect else { return .none }
    attempted = true
    return .reconnect(profile.id)
  }
}

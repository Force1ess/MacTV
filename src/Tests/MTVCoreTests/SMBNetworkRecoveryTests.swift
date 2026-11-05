import Foundation
import Testing

@testable import MTVCore

struct SMBNetworkRecoveryTests {
  func profile(enabled: Bool = true) throws -> SMBProfile {
    try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false,
      reconnectOnNetworkReturn: enabled)
  }
  @Test func coldStartupAndInitialPathObservationNeverReconnect() throws {
    var policy = SMBNetworkRecovery()
    #expect(policy.update(reachable: false) == .none)
    #expect(policy.update(reachable: true) == .none)
    var initial = SMBNetworkRecovery()
    initial.activate(try profile())
    #expect(initial.update(reachable: false) == .none)
    #expect(initial.update(reachable: true) == .none)
  }
  @Test func successfulActiveSourceGetsOneAttemptPerObservedOutage() throws {
    var policy = SMBNetworkRecovery()
    let source = try profile()
    _ = policy.update(reachable: true)
    policy.activate(source)
    #expect(policy.update(reachable: false) == .offline(source.id))
    #expect(policy.update(reachable: false) == .none)
    #expect(policy.update(reachable: true) == .reconnect(source.id))
    #expect(policy.update(reachable: true) == .none)
  }
  @Test func failuresBlockFurtherFlapsUntilManualSuccess() throws {
    var policy = SMBNetworkRecovery()
    let source = try profile()
    _ = policy.update(reachable: true)
    policy.activate(source)
    _ = policy.update(reachable: false)
    _ = policy.update(reachable: true)
    policy.failed()
    _ = policy.update(reachable: false)
    #expect(policy.update(reachable: true) == .none)
    policy.activate(source)
    _ = policy.update(reachable: false)
    #expect(policy.update(reachable: true) == .reconnect(source.id))
    policy.deactivate()
    _ = policy.update(reachable: false)
    #expect(policy.update(reachable: true) == .none)
  }
  @Test func disabledPreferenceAndSourceSwitchDoNotReconnectOldTarget() throws {
    var policy = SMBNetworkRecovery()
    let source = try profile(enabled: false)
    _ = policy.update(reachable: true)
    policy.activate(source)
    #expect(policy.update(reachable: false) == .none)
    #expect(policy.update(reachable: true) == .none)
    _ = policy.update(reachable: false)
    policy.activate(try profile())
    #expect(policy.update(reachable: true) == .none)
  }
  @Test func accountWithoutRememberedPasswordCannotEnableAutomaticRecovery() {
    #expect(throws: (any Error).self) {
      try SMBProfile(
        address: "nas/Movies", username: "u", guest: false, rememberPassword: false,
        reconnectOnNetworkReturn: true)
    }
  }
}

import Foundation
import Security
import Testing
@testable import MTVCore

@Suite(.serialized) struct LegacyKeychainInteractionTests {
  private func allowed() throws -> Bool {
    var value: DarwinBoolean = false
    let status = SecKeychainGetUserInteractionAllowed(&value)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return value.boolValue
  }
  @Test func noninteractiveOperationRestoresPreviousProcessPolicy() throws {
    let before = try allowed()
    let inside = try LegacyKeychainInteraction.perform(allowInteraction: false) { try allowed() }
    #expect(!inside)
    #expect(try allowed() == before)
  }
  @Test func failureStillRestoresPolicy() throws {
    let before = try allowed()
    enum OwnedFailure: Error { case expected }
    do {
      try LegacyKeychainInteraction.perform(allowInteraction: false) { throw OwnedFailure.expected }
      Issue.record("Expected the owned failure")
    } catch OwnedFailure.expected { }
    #expect(try allowed() == before)
  }
  @Test func overlappingAttemptCannotChangeActivePolicy() throws {
    let before = try allowed()
    try LegacyKeychainInteraction.perform(allowInteraction: false) {
      do {
        _ = try LegacyKeychainInteraction.perform(allowInteraction: true) { true }
        Issue.record("An overlapping request must fail without allowing UI")
      } catch {
        #expect((error as NSError).domain == "local.mtv.keychain-interaction")
      }
      let inside = try allowed()
      #expect(!inside)
    }
    #expect(try allowed() == before)
  }
}

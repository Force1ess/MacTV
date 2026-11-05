import Foundation
import Testing
@testable import MTVCore

struct PlaybackResumeTests {
  @Test func pluginNamespacesAndColdRecordsStayIndependent() throws {
    let scope = UUID(); let store = PlaybackResumeStore.isolated(scope: scope)
    defer { store.removeTestDomain() }
    store.save(42, for: "same", source: "first.plugin", duration: 200)
    store.save(75, for: "same", source: "second.plugin", duration: 300)
    store.save(12, for: "same", duration: 100)
    let cold = PlaybackResumeStore.isolated(scope: scope)
    #expect(cold.position(for: "same", source: "first.plugin") == 42)
    #expect(cold.position(for: "same", source: "second.plugin") == 75)
    #expect(cold.position(for: "same") == 12)
    #expect(cold.record(for: "same", source: "first.plugin")?.duration == 200)
    #expect(cold.record(for: "same", source: "first.plugin")?.updatedAt != nil)
    store.save(99, for: "c", source: "a:b")
    #expect(cold.position(for: "b:c", source: "a") == 0)
  }
  @Test func legacyLocalOnlyAndInvalidDataDoesNotReviveOldProgress() throws {
    let scope = UUID(); let store = PlaybackResumeStore.isolated(scope: scope)
    defer { store.removeTestDomain() }
    let defaults = UserDefaults(suiteName: "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased())!
    defaults.set(42.5, forKey: "resume.legacy")
    #expect(store.position(for: "legacy") == 42.5)
    #expect(store.record(for: "legacy")?.duration == nil)
    #expect(store.position(for: "legacy", source: "some.plugin") == 0)
    store.save(60, for: "legacy", duration: 180)
    #expect(store.position(for: "legacy") == 60)
    let bytes = try JSONEncoder().encode(["local", "legacy"])
    defaults.set(Data("bad".utf8), forKey: "resume.v2." + bytes.base64EncodedString())
    #expect(store.position(for: "legacy") == 0)
  }
  @Test func completionAndInvalidValuesCannotOfferMisleadingResume() {
    let store = PlaybackResumeStore.isolated(); defer { store.removeTestDomain() }
    for position in [5.0, 185.0, 200.0, 300.0] {
      store.save(position, for: "long", duration: 200)
      #expect(store.record(for: "long")?.resumablePosition == 0)
    }
    store.save(42, for: "long", duration: 200)
    #expect(store.record(for: "long")?.resumablePosition == 42)
    store.save(10, for: "short", duration: 25)
    #expect(store.record(for: "short")?.resumablePosition == 0)
    for value in [Double.nan, Double.infinity, -1, 0] { store.save(value, for: "long") }
    #expect(store.position(for: "long") == 42)
    store.save(20, for: "unknown", duration: .nan)
    #expect(store.record(for: "unknown")?.duration == nil)
    store.save(20, for: "", source: "local")
    #expect(store.position(for: "") == 0)
  }
}

import Foundation
import Testing
@testable import MTVCore

struct PluginContinuationTests {
  func manifest(_ capabilities: [String] = ["folders", "resolve", "continuation"]) throws -> PluginManifest {
    let object: [String: Any] = ["id": "test.plugin", "name": "Test", "version": "1", "apiVersion": 1,
      "entry": "plugin.js", "domains": [], "capabilities": capabilities]
    return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func value(_ next: MediaItem? = MediaItem(id: "part2", title: "第二部分", source: "untrusted", reference: "part2")) -> PluginContinuation {
    PluginContinuation(currentReference: "part1", collectionReference: "collection", label: "下一P", next: next)
  }
  @Test func nextReferenceIsNormalizedAndPlanDoesNotContainMediaURL() throws {
    let result = try value().validated(manifest: manifest(), currentID: "part1", expectedCurrent: "part1", expectedCollection: "collection")
    #expect(result.next?.source == "test.plugin" && result.next?.reference == "part2" && result.next?.url == nil)
    #expect(result.plan(currentID: "part1")?.label == "下一P")
    #expect(try value(nil).validated(manifest: manifest(), currentID: "part1").plan(currentID: "part1") == nil)
  }
  @Test func lastPartMustBeExplicitNullAndRoundTrips() throws {
    let bytes = try JSONEncoder().encode(value(nil))
    #expect(String(decoding: bytes, as: UTF8.self).contains("\"next\":null"))
    #expect(try JSONDecoder().decode(PluginContinuation.self, from: bytes).next == nil)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PluginContinuation.self, from: Data(#"{"currentReference":"part1","collectionReference":"collection","label":"Next"}"#.utf8))
    }
  }
  @Test func changedScopeSelfLoopsAndRawURLsAreRejected() throws {
    let policy = try manifest()
    #expect(throws: (any Error).self) { try value().validated(manifest: policy, currentID: "part1", expectedCurrent: "other") }
    #expect(throws: (any Error).self) { try value().validated(manifest: policy, currentID: "part1", expectedCollection: "other") }
    for target in [MediaItem(id: "part1", title: "self", reference: "part2"), MediaItem(id: "part2", title: "self", reference: "part1"),
      MediaItem(id: "part2", title: "url", url: "https://media.example/video", reference: "part2"),
      MediaItem(id: "https://media.example/signed?token=secret", title: "url", reference: "part2"),
      MediaItem(id: "part2", title: "folder", reference: "folder", kind: .folder)] {
      #expect(throws: (any Error).self) { try value(target).validated(manifest: policy, currentID: "part1") }
    }
  }
  @Test func capabilityDependenciesAndOpaqueBoundariesAreChecked() throws {
    for capabilities in [["resolve", "folders"], ["resolve", "continuation"], ["folders", "continuation"]] {
      #expect(throws: (any Error).self) { try value().validated(manifest: manifest(capabilities), currentID: "part1") }
    }
    for reference in ["", "https://media.example/part", "file:/private/part", "/private/part", "part\n2", String(repeating: "a", count: 513)] {
      let item = PluginContinuation(currentReference: reference, collectionReference: "collection", label: "Next", next: nil)
      #expect(throws: (any Error).self) { try item.validated(manifest: manifest(), currentID: "part1") }
    }
  }
}

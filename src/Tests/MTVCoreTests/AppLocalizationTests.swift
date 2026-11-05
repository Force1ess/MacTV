import Foundation
import Testing
@testable import MTVCore

struct AppLocalizationTests {
  @Test func visibleErrorsLocalizeButMachineCodesRemainStable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    let resources = root.appendingPathComponent("Contents/Resources/en.lproj")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info: [String: Any] = ["CFBundleIdentifier": "test.mactv.error-copy", "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: root.appendingPathComponent("Contents/Info.plist"))
    let copy = ["Owned visible error": "Translated visible error", "control-owned-code": "This must never replace a protocol code"]
    try PropertyListSerialization.data(fromPropertyList: copy, format: .xml, options: 0)
      .write(to: resources.appendingPathComponent("Localizable.strings"))
    let bundle = try #require(Bundle(url: root))
    #expect(MTVError.message("Owned visible error").localizedDescription(in: bundle) == "Translated visible error")
    #expect(MTVError.code("control-owned-code").localizedDescription(in: bundle) == "control-owned-code")
    #expect(MTVError.code("control-owned-code").errorDescription == "control-owned-code")
  }

  @Test func shippedLanguagesCoverTheSameKeysAndPreserveArguments() throws {
    let root = TestProject.root
    func load(_ language: String, table: String = "Localizable") throws -> [String: String] {
      let file = root.appendingPathComponent("resources/\(language).lproj/\(table).strings")
      return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file),
        options: [], format: nil) as? [String: String])
    }
    func arguments(_ text: String) -> Set<String> {
      let expression = try! NSRegularExpression(pattern: #"\{[0-9]+\}"#)
      let range = NSRange(text.startIndex..., in: text)
      return Set(expression.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
      })
    }
    let english = try load("en"), chinese = try load("zh-Hans")
    let englishPrompts = try load("en", table: "InfoPlist"), chinesePrompts = try load("zh-Hans", table: "InfoPlist")
    #expect(Set(englishPrompts.keys) == Set(chinesePrompts.keys))
    for key in ["NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription", "NSLocalNetworkUsageDescription", "NSAppleMusicUsageDescription"] {
      #expect(!(englishPrompts[key] ?? "").isEmpty && !(chinesePrompts[key] ?? "").isEmpty)
    }
    #expect(Set(english.keys) == Set(chinese.keys))
    for (key, translation) in english {
      #expect(!translation.isEmpty)
      #expect(arguments(key) == arguments(translation), "English placeholders: \(key)")
      #expect(arguments(key) == arguments(chinese[key] ?? ""), "Chinese placeholders: \(key)")
    }
  }
  @Test func interpolationsAreReorderableAndUserContentIsNotReinterpreted() {
    let item = "My {1} movie"
    let value: AppText = "Added \(item) to \("Watchlist")"
    #expect(value.key == "Added {0} to {1}")
    #expect(AppLocalization.render("{1}：{0}", arguments: value.arguments) == "Watchlist：My {1} movie")
  }
  @Test func missingArgumentsDoNotCrashOrExposeUnrelatedValues() {
    #expect(AppLocalization.render("{0} {7}", arguments: ["owned"]) == "owned {7}")
    let value: AppText = "Found \(3) files"
    #expect(value.arguments == ["3"])
  }
}

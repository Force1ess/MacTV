import Foundation

public enum SubtitlePreference {
  private static let aliases: [String: String] = ["zho":"zh", "chi":"zh", "chinese":"zh", "chs":"zh", "cht":"zh", "eng":"en", "english":"en", "jpn":"ja", "japanese":"ja", "kor":"ko", "korean":"ko", "fra":"fr", "fre":"fr", "french":"fr", "deu":"de", "ger":"de", "german":"de", "spa":"es", "spanish":"es", "por":"pt", "rus":"ru", "ita":"it", "ara":"ar"]
  private static let languageNames: [String: String] = Locale.isoLanguageCodes.reduce(into: [:]) { result, code in
    guard let name = Locale(identifier: "en").localizedString(forLanguageCode: code)?.lowercased() else { return }
    let normalized = aliases[code] ?? code
    if result[name] == nil || normalized.count == 2 { result[name] = normalized }
  }
  public static func language(_ value: String) -> String? {
    let value = value.lowercased().replacingOccurrences(of: "_", with: "-")
    if value.contains("中文") || value.contains("简体") || value.contains("繁体") || value.contains("汉语") { return "zh" }
    for part in value.components(separatedBy: CharacterSet(charactersIn: "[]()")) {
      if let code = languageNames[part.trimmingCharacters(in: .whitespaces)] { return code }
    }
    for token in value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter({ !$0.isEmpty }) {
      if let alias = aliases[token] { return alias }
      if let code = languageNames[token] { return code }
      if token.count == 2, Locale.isoLanguageCodes.contains(token) { return token }
    }
    return nil
  }
  public static func rank(language: String?, title: String, preferredLanguages: [String] = Locale.preferredLanguages) -> Int {
    let primary = preferredLanguages.first.flatMap(Self.language) ?? "en"
    let ext = (title as NSString).pathExtension.lowercased()
    let titleLanguage: String?
    if ["srt", "ass", "ssa", "vtt"].contains(ext) {
      titleLanguage = (title as NSString).deletingPathExtension.components(separatedBy: ".").dropFirst().reversed().compactMap(Self.language).first
    } else { titleLanguage = Self.language(title) }
    let candidate = language.flatMap(Self.language) ?? titleLanguage
    if candidate == primary { return 0 }
    if candidate == "en" { return 1 }
    return 2
  }
  public static func preferredIndex(languages: [String?], titles: [String], preferredLanguages: [String] = Locale.preferredLanguages) -> Int? {
    guard languages.count == titles.count, !titles.isEmpty else { return nil }
    return titles.indices.min { rank(language: languages[$0], title: titles[$0], preferredLanguages: preferredLanguages)
      < rank(language: languages[$1], title: titles[$1], preferredLanguages: preferredLanguages) }
  }
  public static var playerLanguages: String {
    let primary = Locale.preferredLanguages.first.flatMap(Self.language) ?? "en"
    let codes = primary == "zh" ? ["zh", "zho", "chi"] : [primary]
    return (codes + (primary == "en" ? [] : ["en", "eng"]) + ["any"]).joined(separator: ",")
  }
}

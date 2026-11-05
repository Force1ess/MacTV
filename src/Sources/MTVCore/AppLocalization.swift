import Foundation

/// App-owned messages only. Provider content, filenames and user input must
/// remain verbatim. Numbered placeholders allow translations to reorder values.
public struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
  public let key: String
  public let arguments: [String]
  public init(stringLiteral value: String) { key = value; arguments = [] }
  public init(stringInterpolation value: StringInterpolation) { key = value.key; arguments = value.arguments }
  public struct StringInterpolation: StringInterpolationProtocol, Sendable {
    var key = ""
    var arguments: [String] = []
    public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
    public mutating func appendLiteral(_ value: String) { key += value }
    public mutating func appendInterpolation<Value>(_ value: Value) {
      key += "{\(arguments.count)}"; arguments.append(String(describing: value))
    }
  }
}

public enum AppLocalization {
  public static func text(_ value: AppText, bundle: Bundle = .main) -> String {
    render(bundle.localizedString(forKey: value.key, value: value.key, table: "Localizable"), arguments: value.arguments)
  }
  /// Parse the resource template once; never interpret placeholders introduced
  /// by a user's filename or other interpolation argument.
  public static func render(_ template: String, arguments: [String]) -> String {
    var output = "", cursor = template.startIndex
    while cursor < template.endIndex {
      if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
        let index = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(index) {
        output += arguments[index]; cursor = template.index(after: end)
      } else { output.append(template[cursor]); cursor = template.index(after: cursor) }
    }
    return output
  }
}

public func L(_ value: AppText) -> String { AppLocalization.text(value) }

/// Localize a fixed, app-owned label from a legacy action model.
public func LT(_ value: String, bundle: Bundle = .main) -> String {
  bundle.localizedString(forKey: value, value: value, table: "Localizable")
}

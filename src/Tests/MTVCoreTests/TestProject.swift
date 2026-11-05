import Foundation

enum TestProject {
  static let root: URL = {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) { return directory }
      directory.deleteLastPathComponent()
    }
    preconditionFailure("Cannot locate the package root for repository fixtures")
  }()
}

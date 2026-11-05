import Foundation

/// A shared, deterministic naming policy. Does not enumerate or read files.
public enum LocalArtworkCandidates {
  public static let extensions = ["jpg", "jpeg", "png", "webp"]
  public static func named(_ stem: URL) -> [URL] { extensions.map { stem.appendingPathExtension($0) } }
  public static func posters(in directory: URL) -> [URL] { named(directory.appendingPathComponent("poster")) }
  public static func backdrops(in directory: URL) -> [URL] { named(directory.appendingPathComponent("fanart")) }
  public static func posters(for file: URL, seriesRoot: URL? = nil) -> [URL] {
    let folder = file.deletingLastPathComponent()
    var values = named(file.deletingPathExtension())
      + named(folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-poster"))
      + posters(in: folder) + named(folder.appendingPathComponent("folder"))
    if let seriesRoot { values += posters(in: seriesRoot) }
    values += posters(in: folder.deletingLastPathComponent())
    var seen = Set<URL>()
    return values.filter { seen.insert($0).inserted }
  }
}

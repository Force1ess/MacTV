import Foundation

/// Public Music framework records remain native. Plugin pages contain stable
/// track/collection references and display metadata, never filesystem URLs.
public struct MusicLibraryCatalog: Decodable {
  public struct Track: Decodable {
    public let id: String, title: String, subtitle: String, location: String
    public let albumID: String?, albumTitle: String?, trackNumber: String?
  }
  public struct Playlist: Decodable { public let id: String, name: String, tracks: [String] }
  public let schema: Int
  public let items: [Track]
  public let playlists: [Playlist]?
  public func page(reference: String, query: String, owner: String) throws -> [MediaItem] {
    guard schema == 1, items.count <= 50_000, (playlists?.count ?? 0) <= 1000 else { throw MTVError.message("Invalid Music library catalog") }
    func media(_ track: Track) -> MediaItem {
      MediaItem(id:track.id,title:track.title,subtitle:track.subtitle,source:owner,reference:track.id,kind:.audio,artworkReference:track.id)
    }
    if reference.isEmpty && query.isEmpty {
      return [MediaItem(id:"music-albums",title:LT("Albums"),source:owner,reference:"albums",kind:.folder),
        MediaItem(id:"music-playlists",title:LT("Playlists"),source:owner,reference:"playlists",kind:.folder),
        MediaItem(id:"music-tracks",title:LT("Songs"),subtitle:String(items.count),source:owner,reference:"tracks",kind:.folder)]
    }
    if reference == "albums" {
      let grouped = Dictionary(grouping:items,by:{$0.albumID ?? "unknown"})
      return grouped.keys.sorted().compactMap { key in
        guard let first = grouped[key]?.first else { return nil }
        return MediaItem(id:"album:"+key,title:first.albumTitle?.isEmpty == false ? first.albumTitle! : LT("Unknown Album"),
          subtitle:String(grouped[key]!.count),source:owner,reference:"album:"+key,kind:.folder,artworkReference:first.id)
      }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    if reference == "playlists" {
      return (playlists ?? []).filter{!$0.tracks.isEmpty}.map {
        MediaItem(id:"playlist:"+$0.id,title:$0.name,subtitle:String($0.tracks.count),source:owner,reference:"playlist:"+$0.id,kind:.folder,artworkReference:$0.tracks.first)
      }
    }
    let tracks: [Track]
    if reference.hasPrefix("album:") {
      let id = String(reference.dropFirst(6))
      tracks = items.filter{($0.albumID ?? "unknown")==id}.sorted {
        (Int($0.trackNumber ?? "0") ?? 0) < (Int($1.trackNumber ?? "0") ?? 0)
      }
    } else if reference.hasPrefix("playlist:") {
      let id = String(reference.dropFirst(9))
      guard let playlist = playlists?.first(where:{$0.id==id}) else { throw MTVError.message("This playlist is no longer available.") }
      let index = Dictionary(items.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
      tracks = playlist.tracks.compactMap{index[$0]}
    } else {
      guard reference.isEmpty || reference == "tracks" else { throw MTVError.message("Invalid music collection") }
      tracks = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    return tracks.map(media)
  }
}

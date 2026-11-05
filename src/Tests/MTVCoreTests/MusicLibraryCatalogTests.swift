import Foundation
import Testing
@testable import MTVCore

struct MusicLibraryCatalogTests {
  private func catalog() throws -> MusicLibraryCatalog {
    let data: [String:Any] = ["schema":1,"items":[
      ["id":"1","title":"Second","subtitle":"Artist","location":"file:///fixture/second.m4a","albumID":"7","albumTitle":"Album","trackNumber":"2"],
      ["id":"2","title":"First","subtitle":"Artist","location":"file:///fixture/first.m4a","albumID":"7","albumTitle":"Album","trackNumber":"1"]
    ],"playlists":[["id":"8","name":"My list","tracks":["1","2"]]]]
    return try JSONDecoder().decode(MusicLibraryCatalog.self,from:JSONSerialization.data(withJSONObject:data))
  }
  @Test func albumAndPlaylistOrdersStayDistinctAndURLsRemainNative() throws {
    let catalog = try catalog()
    #expect(try catalog.page(reference:"",query:"",owner:"fixture.music").map(\.reference) == ["albums","playlists","tracks"])
    let albums = try catalog.page(reference:"albums",query:"",owner:"fixture.music")
    #expect(albums.count == 1 && albums[0].title == "Album" && albums[0].artworkReference == "1")
    let album = try catalog.page(reference:"album:7",query:"",owner:"fixture.music")
    #expect(album.map(\.id) == ["2","1"])
    let playlist = try catalog.page(reference:"playlist:8",query:"",owner:"fixture.music")
    #expect(playlist.map(\.id) == ["1","2"])
    #expect(!String(decoding:try JSONEncoder().encode(playlist),as:UTF8.self).contains("file:///"))
    #expect(throws: Error.self) { try catalog.page(reference:"playlist:missing",query:"",owner:"fixture.music") }
  }
}

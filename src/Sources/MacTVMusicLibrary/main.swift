import Darwin
import Foundation
import iTunesLibrary

// A bounded, native-only response on stdout. No network, private database
// parser, account credentials, Music app control or filesystem mutations.
signal(SIGTERM, SIG_DFL)
let parentPID = getppid()
let parentWatch = DispatchSource.makeTimerSource(queue:.global(qos:.utility))
parentWatch.schedule(deadline:.now()+1,repeating:1)
parentWatch.setEventHandler { if getppid() != parentPID { _exit(70) } }
parentWatch.resume()
DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+20) { _exit(70) }
do {
  guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--read-local-library-v1" else { exit(64) }
  let library = try ITLibrary(apiVersion:"1.0")
  guard library.allMediaItems.count <= 50_000 else { throw CocoaError(.fileReadTooLarge) }
  var items: [[String:String]] = []
  var playable = Set<String>()
  for item in library.allMediaItems where item.mediaKind.rawValue == 2 {
    guard !item.isDRMProtected, let url = item.location, url.isFileURL else { continue }
    playable.insert(item.persistentID.stringValue)
    items.append(["albumID":item.album.persistentID.stringValue,"albumTitle":item.album.title ?? "","trackNumber":String(item.trackNumber),"id":item.persistentID.stringValue,"title":String(item.title.prefix(512)),
      "subtitle":String([item.artist?.name,item.album.title].compactMap{$0}.joined(separator:" · ").prefix(1024)),
      "location":url.absoluteString])
  }
  guard library.allPlaylists.count <= 1000 else { throw CocoaError(.fileReadTooLarge) }
  var playlists: [[String:Any]] = []
  var associations = 0
  for playlist in library.allPlaylists {
    let tracks = playlist.items.map { $0.persistentID.stringValue }.filter { playable.contains($0) }
    guard !tracks.isEmpty else { continue }
    associations += tracks.count
    guard associations <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
    playlists.append(["id":playlist.persistentID.stringValue,"name":playlist.name,"tracks":tracks])
  }
  let data = try JSONSerialization.data(withJSONObject:["schema":1,"items":items,"playlists":playlists])
  guard data.count <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
  try FileHandle.standardOutput.write(contentsOf:data)
} catch {
  let error = error as NSError
  if let data = try? JSONSerialization.data(withJSONObject:["schema":1,"errorDomain":error.domain,"errorCode":error.code]) {
    try? FileHandle.standardOutput.write(contentsOf:data)
  }
  exit(1)
}

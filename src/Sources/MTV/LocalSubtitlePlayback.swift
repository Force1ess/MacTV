import Foundation
import MTVCore

struct LocalSubtitlePlaybackContext {
  let token = UUID()
  let media: URL
  let item: MediaItem
  let access: ScopedFileAccess
}
struct SubtitlePlaybackRestart {
  let subtitle: PreparedLocalSubtitle?
  let position: Double
  let paused: Bool
  var userSubtitleChoice = true
  var engine: PlaybackEngineChoice = .mpv
}

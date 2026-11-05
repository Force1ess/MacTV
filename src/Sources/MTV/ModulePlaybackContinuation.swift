import Foundation
import MTVCore

struct ModulePlaybackContinuation {
  let token = UUID()
  let pluginID: String
  let version: String
  let directory: URL
  let sessionAccess: PluginClient.SessionAccess
  let currentID: String
  var value: PluginContinuation
}

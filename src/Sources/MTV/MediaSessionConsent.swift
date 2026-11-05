import SwiftUI
import MTVCore

struct MediaSessionConsent {
  let requestID: UUID
  let pluginID: String
  let host: String
  let item: MediaItem
  let fromBeginning: Bool
}

extension AppModel {
  func hasMediaSessionApproval(pluginID: String, host: String) -> Bool {
    if revokedMediaSessionScopes.contains(pluginID + "@" + host) { return false }
    if pluginID == "mtv.quark", host == FirstPartyMediaScope.quarkHost,
      CommandLine.arguments.contains("--enable-approved-quark-media-session") { return true }
    if CommandLine.arguments.contains("--ui-smoke"), !CommandLine.arguments.contains("--live-services") { return testMediaSessionApprovals.contains(pluginID + "@" + host) }
    return MediaSessionApprovalStore().permits(pluginID: pluginID, host: host)
  }
  func handleMediaSessionConsent(_ action: InputAction) {
    guard let pending = mediaSessionConsent else { return }
    switch action {
    case .up, .left: mediaSessionConsentSelection = max(0, mediaSessionConsentSelection - 1)
    case .down, .right: mediaSessionConsentSelection = min(1, mediaSessionConsentSelection + 1)
    case .select:
      guard mediaSessionConsentSelection == 0 else { mediaSessionConsent = nil; return }
      guard pending.requestID == playbackRequestID, pending.pluginID == "mtv.quark", FirstPartyMediaScope.isQuarkPlaybackHost(pending.host) else { mediaSessionConsent = nil; return }
      do {
        if CommandLine.arguments.contains("--ui-smoke") { testMediaSessionApprovals.insert(pending.pluginID + "@" + pending.host) }
        else { MediaSessionApprovalStore().approveQuarkPlaybackService() }
        revokedMediaSessionScopes.remove(pending.pluginID + "@" + pending.host)
        mediaSessionConsent = nil
        if pending.item.kind == .photo { openNativeMedia(pending.item) }
        else { play(pending.item, fromBeginning: pending.fromBeginning) }
      } catch { mediaSessionConsent = nil; notice = error.localizedDescription }
    case .back, .menu: mediaSessionConsent = nil
    case .home: mediaSessionConsent = nil; handle(.home)
    default: break
    }
  }
}

struct MediaSessionConsentPanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    if let pending = model.mediaSessionConsent {
      TVDialog(title: L("Use Quark sign-in"), subtitle: L("Quark needs your current sign-in to open this item."), symbol: "play.shield", brand: "mtv.quark") {
        VStack(alignment: .leading, spacing: 18) {
          Text(L("Allow MacTV to use your sign-in only for Quark's official media services. Sign-in data stays in the native app."))
            .font(.system(size: 19)).fixedSize(horizontal: false, vertical: true)
          Text(pending.host).font(.system(size: 15, design: .monospaced)).foregroundStyle(.secondary)
          ForEach(0..<2) { index in
            TVButton(selected: model.mediaSessionConsentSelection == index,
              action: { model.mediaSessionConsentSelection = index; model.handle(.select) },
              hover: { model.mediaSessionConsentSelection = index }) {
              Text(index == 0 ? L("Allow and Open") : L("Not Now")).font(.system(size: 21, weight: .medium))
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
  }
}

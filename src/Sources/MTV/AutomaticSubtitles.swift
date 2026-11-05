import AVFoundation
import MTVCore

extension AppModel {
  /// Never blocks the first frame or scans outside the selected source boundary.
  func prepareAutomaticLocalSubtitle() {
    guard automaticSubtitleTask == nil, !hasUserSubtitleChoice, let context = localSubtitleContext,
      mpvEngine?.subtitle == nil, vlcEngine?.subtitle == nil else { return }
    let mpv = mpvEngine, vlc = vlcEngine, av = player
    automaticSubtitleTask = Task { [weak self] in
      guard let self else { return }
      do {
        let files = try await subtitleFiles.discover(for: context.media, access: context.access).candidates
        guard !Task.isCancelled, !hasUserSubtitleChoice, localSubtitleContext?.token == context.token else { return }
        guard let index = SubtitlePreference.preferredIndex(languages: files.map { _ in nil }, titles: files.map(\.filename)) else { return }
        let candidate = files[index]
        var currentRank = 3
        if let mpv {
          let menu = await mpv.tracks(subtitles: true)
          if let track = menu.options.first(where: { $0.trackID == menu.selectedID }), menu.selectedID >= 0 {
            currentRank = SubtitlePreference.rank(language: nil, title: track.title)
          }
        } else if let vlc {
          let menu = await vlc.tracks(subtitles: true)
          if let track = menu.options.first(where: { $0.trackID == menu.selectedID }), menu.selectedID >= 0 {
            currentRank = SubtitlePreference.rank(language: nil, title: track.title)
          }
        } else if let item = av?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
          let option = item.currentMediaSelection.selectedMediaOption(in: group) {
          currentRank = SubtitlePreference.rank(language: option.extendedLanguageTag, title: option.displayName)
        }
        guard SubtitlePreference.rank(language: nil, title: candidate.filename) < currentRank else { return }
        if let asset = av?.currentItem?.asset, try await asset.load(.hasProtectedContent) { return }
        let prepared = try await subtitleFiles.prepare(candidate, access: context.access)
        guard !Task.isCancelled, !hasUserSubtitleChoice, localSubtitleContext?.token == context.token else { return }
        if let mpv, mpvEngine === mpv { _ = try await mpv.loadSubtitle(prepared) }
        else if (vlc != nil && vlcEngine === vlc) || (av != nil && player === av) {
          _ = restartForSubtitle(prepared, context: context, automatic: true)
        }
      } catch {
        // A missing/denied sidecar must never stop an otherwise playable film.
        // Embedded captions and the manual subtitle menu remain available.
      }
    }
  }
}

import AVFoundation
import MTVCore

extension AppModel {
  private func withLocalSubtitles(_ menu: PlaybackTrackMenu, context: LocalSubtitlePlaybackContext?, loaded: PreparedLocalSubtitle? = nil, system: Bool) async throws -> PlaybackTrackMenu {
    guard let context else { return menu }
    var result = menu
    do {
      let listing = try await subtitleFiles.discover(for: context.media, access: context.access)
      guard localSubtitleContext?.token == context.token, !Task.isCancelled else { throw CancellationError() }
      if !VLCPlaybackEngine.isAvailable, !MPVPlaybackEngine.isAvailable, !listing.candidates.isEmpty {
        result.message = "此构建未包含通用播放组件，暂不能导入外挂字幕。"; return result
      }
      var files = listing.candidates
      if let loaded, !files.contains(loaded.source) { files.insert(loaded.source, at: 0) }
      result.limited = result.limited || listing.limited || files.count > 64
      for file in files.prefix(64) {
        result.options.append(PlaybackTrackOption(subtitle: file,
          detail: (system ? "外挂字幕 · 将从当前位置使用通用播放器" : (loaded?.source == file ? "外挂字幕 · 已载入的副本" : "外挂字幕 · 从当前位置载入"))
            + (file.url.pathExtension.lowercased() == "vtt" ? " · WebVTT 复杂样式可能改变" : "")))
      }
    } catch is CancellationError { throw CancellationError() }
    catch { result.message += (result.message.isEmpty ? "" : "\n") + "外挂字幕列表暂时无法读取；已有轨道仍可选择。" }
    return result
  }
  private func useLocalSubtitle(_ candidate: LocalSubtitleCandidate, context: LocalSubtitlePlaybackContext) async -> Bool {
    do {
      if let asset = player?.currentItem?.asset, try await asset.load(.hasProtectedContent) { return false }
      let prepared = try await subtitleFiles.prepare(candidate, access: context.access)
      guard !Task.isCancelled else { return false }
      return restartForSubtitle(prepared, context: context)
    } catch { return false }
  }
  func openPlaybackTracks(_ kind: PlaybackTrackKind) {
    let subtitles = kind == .subtitles
    let context = subtitles ? localSubtitleContext : nil
    if let engine = mpvEngine {
      playbackTracks.present(kind,load:{ [weak self,weak engine] in
        guard let self,let engine,self.mpvEngine === engine else { throw CancellationError() }
        let menu = await engine.tracks(subtitles:subtitles)
        return subtitles ? try await self.withLocalSubtitles(menu, context: context, loaded: engine.subtitle, system: false) : menu
      },apply:{ [weak self,weak engine] option in
        guard let self,let engine,self.mpvEngine === engine else { return false }
        if subtitles { self.hasUserSubtitleChoice = true; self.automaticSubtitleTask?.cancel() } else { self.hasUserAudioChoice = true }
        if let file = option.subtitle, let context {
          guard let prepared = try? await self.subtitleFiles.prepare(file, access: context.access),
            !Task.isCancelled, self.localSubtitleContext?.token == context.token, self.mpvEngine === engine else { return false }
          return (try? await engine.loadSubtitle(prepared)) == true
        }
        guard let id = option.trackID else { return false }
        return await engine.selectTrack(subtitles:subtitles,id:id)
      })
    } else if let engine = vlcEngine {
      playbackTracks.present(kind, load: { [weak self, weak engine] in
        guard let engine, self?.vlcEngine === engine else { throw MTVError.message("播放内容已改变") }
        let menu = await engine.tracks(subtitles: subtitles)
        guard let self, self.vlcEngine === engine else { throw CancellationError() }
        return subtitles ? try await self.withLocalSubtitles(menu, context: context, loaded: engine.subtitle, system: false) : menu
      }, apply: { [weak self, weak engine] option in
        guard let engine, self?.vlcEngine === engine, !Task.isCancelled else { return false }
        if subtitles { self?.hasUserSubtitleChoice = true; self?.automaticSubtitleTask?.cancel() } else { self?.hasUserAudioChoice = true }
        if let file = option.subtitle, let self, let context {
          if engine.subtitle?.source == file, await engine.selectLoadedSubtitle(file.url) { return true }
          return await self.useLocalSubtitle(file, context: context)
        }
        guard let id = option.trackID else { return false }
        if subtitles, id == -1, await engine.externalSubtitlePending(), let context { return self?.restartForSubtitle(nil, context: context) == true }
        let accepted = await engine.selectTrack(subtitles: subtitles, id: id)
        if accepted, self?.vlcEngine === engine { self?.playbackState = id == -1 ? "字幕已关闭" : "已应用所选\(kind.title)" }
        return accepted && self?.vlcEngine === engine
      })
    } else if let player, let item = player.currentItem {
      var group: AVMediaSelectionGroup?
      playbackTracks.present(kind, load: { [weak self, weak item] in
        guard let item else { throw MTVError.message("播放内容已改变") }
        group = try await item.asset.loadMediaSelectionGroup(for: subtitles ? .legible : .audible)
        guard self?.player?.currentItem === item, !Task.isCancelled else { throw CancellationError() }
        let available = group?.options ?? []
        var options = available.prefix(256).enumerated().map { PlaybackTrackOption(id: Int32($0.offset), title: $0.element.displayName) }
        if subtitles { options.insert(PlaybackTrackOption(id: -1, title: "字幕关闭"), at: 0) }
        let selected = group.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
        let index = selected.flatMap { available.firstIndex(of: $0) }
        let menu = PlaybackTrackMenu(options: options, selectedID: index.map(Int32.init) ?? -1, limited: available.count > 256)
        guard let self else { throw CancellationError() }
        return subtitles ? try await self.withLocalSubtitles(menu, context: context, system: true) : menu
      }, apply: { [weak self, weak item] option in
        guard let item, self?.player?.currentItem === item, !Task.isCancelled else { return false }
        if subtitles { self?.hasUserSubtitleChoice = true; self?.automaticSubtitleTask?.cancel() } else { self?.hasUserAudioChoice = true }
        if let file = option.subtitle, let self, let context { return await self.useLocalSubtitle(file, context: context) }
        guard let id = option.trackID else { return false }
        guard let group else { return subtitles && id == -1 }
        let option: AVMediaSelectionOption?
        if subtitles && id == -1 { option = nil }
        else {
          guard id >= 0, group.options.indices.contains(Int(id)) else { return false }
          option = group.options[Int(id)]
        }
        if subtitles { self?.hasUserSubtitleChoice = true } else { self?.hasUserAudioChoice = true }
        item.select(option, in: group)
        let applied = item.currentMediaSelection.selectedMediaOption(in: group) == option
        if applied { self?.playbackState = option?.displayName ?? "字幕已关闭" }
        return applied
      })
    }
  }
}

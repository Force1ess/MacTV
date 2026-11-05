import AppKit
import AVFoundation
import ImageIO
import MTVCore
import SwiftUI

@MainActor final class NativeMediaController: ObservableObject {
  @Published private(set) var item: MediaItem?
  @Published private(set) var image: NSImage?
  @Published private(set) var audioArtwork: NSImage?
  @Published private(set) var message = ""
  @Published private(set) var paused = false
  @Published private(set) var audioState = "idle"
  @Published private(set) var volume: Float = 1
  var systemVolumeScale: Float = 1 { didSet { player?.volume = volume * systemVolumeScale } }
  private var volumeBeforeMute: Float = 1
  private var audioObservation: NSKeyValueObservation?
  private var audioStatusObservation: NSKeyValueObservation?
  private var endedObserver: NSObjectProtocol?
  @Published private(set) var elapsed: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var imageFailure: [String: String] = [:]
  private var player: AVPlayer?
  private var observer: Any?
  private var loading: Task<Void, Never>?
  private var generation = UUID()
  var onStep: ((Int) -> Void)?
  var isPresented: Bool { item != nil }
  func openRemote(_ item: MediaItem, read: @escaping @Sendable () async throws -> Data, failure: @escaping @MainActor (Error) -> Void) {
    close(); self.item = item; let attempt = generation
    loading = Task {
      do {
        let data = try await read()
        let decoded = await Task.detached(priority:.userInitiated) { () -> CGImage? in
          guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return nil }
          return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096] as CFDictionary)
        }.value
        guard !Task.isCancelled, generation == attempt else { return }
        guard let decoded else { imageFailure = ["stage":"decode"]; message = L("This image could not be opened."); return }
        image = NSImage(cgImage:decoded,size:NSSize(width:decoded.width,height:decoded.height))
      } catch {
        guard !Task.isCancelled, generation == attempt else { return }
        let value = error as NSError
        imageFailure = ["stage":"download","domain":value.domain,"code":String(value.code)]
        message = L("This image could not be opened.")
        failure(error)
      }
    }
  }
  func open(_ item: MediaItem, url: URL, access: ScopedFileAccess) {
    close(); self.item = item; let attempt = generation
    if item.kind == .photo {
      loading = Task {
        let decoded = await Task.detached(priority:.userInitiated) { () -> (CGImage?, [String:String]) in
          do {
            let data = try ScopedFileReader.read(url,access:access,maximumBytes:15_000_000)
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096] as CFDictionary) else { return (nil,["stage":"decode"]) }
            return (image,[:])
          } catch {
            let error = error as NSError
            var details = ["stage":"read", "domain":error.domain, "code":String(error.code)]
            if case .within(let root) = access, let canonical = try? ScopedFileReader.canonicalPath(url) {
              details["canonicalPathWithinRoot"] = String(canonical.hasPrefix(root.path + "/"))
            }
            return (nil,details)
          }
        }.value
        guard !Task.isCancelled, generation == attempt else { return }
        imageFailure = decoded.1
        if let decoded = decoded.0 { image = NSImage(cgImage:decoded,size:NSSize(width:decoded.width,height:decoded.height)) }
        else { message = L("This image could not be opened.") }
      }
    } else {
      let player = AVPlayer(url:url); self.player = player; audioState = "loading"
      do { player.audioOutputDeviceUniqueID = try AudioOutputHardware.resolve()?.uid }
      catch { message = error.localizedDescription; audioState = "failed"; return }
      player.volume = volume * systemVolumeScale
      if let track = item.reference {
        loading = Task {
          guard let data = try? await MusicArtwork.shared.data(owner:item.source,track:track), !Task.isCancelled,
            let source = CGImageSourceCreateWithData(data as CFData,nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
              kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:800] as CFDictionary), generation == attempt else { return }
          audioArtwork = NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
        }
      }
      if let currentItem = player.currentItem {
        audioStatusObservation = currentItem.observe(\.status,options:[.initial,.new]) { [weak self,weak player] value, _ in
          let failed = value.status == .failed
          Task { @MainActor in
            guard let self, self.player === player, self.generation == attempt, failed else { return }
            self.audioState = "failed"; self.message = L("This audio file could not be played.")
          }
        }
        endedObserver = NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:currentItem,queue:.main) { [weak self,weak player] _ in
          Task { @MainActor in
            guard let self, self.player === player, self.generation == attempt else { return }
            self.audioState = "ended"; self.paused = true; self.onStep?(1)
          }
        }
      }
      audioObservation = player.observe(\.timeControlStatus,options:[.initial,.new]) { [weak self,weak player] _, _ in
        Task { @MainActor in
          guard let self, let player, self.player === player, self.generation == attempt else { return }
          guard player.currentItem?.status != .failed, self.audioState != "ended" else { return }
          self.audioState = player.timeControlStatus == .playing ? "playing" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "buffering" : "paused"
        }
      }
      observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.5,preferredTimescale:600),queue:.main) { [weak self,weak player] time in
        Task { @MainActor in
          guard let self, self.player === player, self.generation == attempt else { return }
          self.elapsed = time.seconds.isFinite ? time.seconds : 0
          if let value = player?.currentItem?.duration.seconds, value.isFinite { self.duration = value }
          if player?.currentItem?.status == .failed { self.message = L("This audio file could not be played.") }
        }
      }
      player.play()
    }
  }
  func handle(_ action: InputAction) {
    switch action {
    case .back, .home, .menu: close()
    case .left: if item?.kind == .photo { onStep?(-1) } else { seek(-15) }
    case .right: if item?.kind == .photo { onStep?(1) } else { seek(15) }
    case .up: if item?.kind == .audio { onStep?(-1) }
    case .down: if item?.kind == .audio { onStep?(1) }
    case .select: if let player { paused.toggle(); if paused { player.pause() } else { player.play() } }
    default: break
    }
  }
  func seekTo(_ seconds: Double) -> Bool {
    guard let player, seconds.isFinite, seconds >= 0, duration > 0, seconds < duration else { return false }
    player.seek(to:CMTime(seconds:seconds,preferredTimescale:600)); return true
  }
  func setOutput(_ output: AudioOutputDevice?) { player?.audioOutputDeviceUniqueID = output?.uid }
  func volumeKey(_ key: Int) {
    if key == 7 {
      if volume > 0 { volumeBeforeMute = volume; volume = 0 } else { volume = max(0.05,volumeBeforeMute) }
    } else { volume = min(1,max(0,volume + (key == 0 ? 0.0625 : -0.0625))) }
    player?.volume = volume * systemVolumeScale
  }
  private func seek(_ offset: Double) {
    guard let player, duration > 0 else { return }
    player.seek(to:CMTime(seconds:min(max(0,elapsed+offset),duration),preferredTimescale:600))
  }
  func close() {
    generation = UUID(); loading?.cancel(); loading = nil
    if let observer, let player { player.removeTimeObserver(observer) }
    if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }; endedObserver = nil
    audioStatusObservation = nil; audioArtwork = nil
    observer = nil; audioObservation = nil; player?.pause(); player = nil; item = nil; image = nil; audioState = "idle"
    elapsed = 0; duration = 0; paused = false; message = ""; imageFailure = [:]
  }
}

struct NativeMediaPanel: View {
  @ObservedObject var controller: NativeMediaController
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let image = controller.image { Image(nsImage:image).resizable().scaledToFit().padding(.bottom,90) }
      if controller.item?.kind == .audio {
        VStack(spacing:26) {
          if let image = controller.audioArtwork {
            Image(nsImage:image).resizable().scaledToFit().frame(width:220,height:220).clipShape(RoundedRectangle(cornerRadius:20))
          } else { Image(systemName:"music.note").font(.system(size:100)).foregroundStyle(.white.opacity(0.75)) }
          Text(controller.item?.title ?? "").font(.system(size:40,weight:.bold))
          Text(controller.item?.subtitle ?? "").font(.title2).foregroundStyle(.secondary)
          if controller.duration > 0 { ProgressView(value:controller.elapsed,total:max(controller.elapsed,controller.duration)).frame(width:600) }
          Text(LT(controller.audioState.capitalized)).foregroundStyle(.secondary)
          Label("\(Int(controller.volume*100))%",systemImage:controller.volume == 0 ? "speaker.slash":"speaker.wave.2").foregroundStyle(.secondary)
          Text(L("← → 15s   ·   ↑ ↓ Tracks   ·   Enter Play/Pause")).foregroundStyle(.secondary)
        }
      }
      VStack {
        Spacer()
        HStack {
          Text(controller.item?.title ?? "").font(.title3).lineLimit(1)
          Spacer()
          if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.orange) }
          Button { controller.close() } label: { Label(L("返回"),systemImage:"arrow.uturn.backward").padding(18) }.buttonStyle(.plain)
        }.padding(24).background(.black.opacity(0.7))
      }
    }.foregroundStyle(.white)
  }
}

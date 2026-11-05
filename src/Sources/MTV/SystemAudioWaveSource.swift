import AVFoundation
import Darwin
import Foundation
import MTVCore

enum SystemAudioWaveIneligible: LocalizedError {
  case unsupported(String), unedited, outsideScope
  var errorDescription: String? {
    switch self {
    case .unsupported(let reason): return reason
    case .unedited: return "音轨为单段，保留默认音轨"
    case .outsideScope: return "音轨已超出当前所选目录范围"
    }
  }
}

/// Native bounded decoder for one explicitly scoped file and playback lifetime.
final class SystemAudioWaveSource: LoopbackByteSource, @unchecked Sendable {
  static var ownedFixtureURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4")
  }
  let wave: FloatAudioWave
  let budget: AudioReadBudget
  var length: Int { wave.length }
  let mime = "audio/wav"
  var maximumReadBytes: Int { wave.maximumReadBytes }
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private let file: URL
  private let access: ScopedFileAccess
  private let identity: [Int64]
  private let queue = DispatchQueue(label: "local.mtv.preview.system-audio")
  private let lock = NSLock()
  private var closed = false
  private var failure: String?
  private var reads = 0, largestReadFrames = 0

  private init(file: URL, asset: AVURLAsset, track: AVAssetTrack, wave: FloatAudioWave,
    identity: [Int64], startFrame: Int64, access: ScopedFileAccess) {
    self.file = file; self.asset = asset; self.track = track; self.wave = wave; self.identity = identity
    self.access = access
    budget = AudioReadBudget(wave: wave, startFrame: startFrame)
  }
  private static func stamp(_ url: URL, access: ScopedFileAccess) throws -> [Int64] {
    let root: URL
    switch access {
    case .within(let value): root = value
    case .verifiedSMB(let share): try share.validateCurrentMount(); root = share.directory
    default: throw CocoaError(.fileReadNoPermission)
    }
    guard url.isFileURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.host == nil || url.host == "" || url.host == "localhost" else { throw CocoaError(.fileReadNoPermission) }
    let boundary = try ScopedFileReader.canonicalPath(root)
    guard try ScopedFileReader.canonicalPath(url) == url.path else { throw CocoaError(.fileReadNoPermission) }
    guard url.path.hasPrefix(boundary == "/" ? "/" : boundary + "/") else { throw SystemAudioWaveIneligible.outsideScope }
    var value = stat()
    guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size > 0 else { throw CocoaError(.fileReadNoPermission) }
    return [Int64(value.st_dev), Int64(bitPattern: value.st_ino), value.st_size,
      Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec),
      Int64(value.st_ctimespec.tv_sec), Int64(value.st_ctimespec.tv_nsec)]
  }
  static func prepareOwnedFixture(start: Double) async throws -> SystemAudioWaveSource {
    guard CommandLine.arguments.contains("--ui-smoke"), start.isFinite, (0...45).contains(start) else { throw CocoaError(.fileReadNoPermission) }
    let file = ownedFixtureURL
    return try await prepare(file: file, start: start, access: .within(file.deletingLastPathComponent()))
  }
  static func prepare(file: URL, start: Double, access: ScopedFileAccess, requireEdits: Bool = false) async throws -> SystemAudioWaveSource {
    guard start.isFinite, (0...86400).contains(start) else { throw MTVError.message("音轨的播放位置无效") }
    let identity = try stamp(file, access: access), asset = AVURLAsset(url: file)
    return try await withTaskCancellationHandler(operation: {
      guard try await !asset.load(.hasProtectedContent) else { throw SystemAudioWaveIneligible.unsupported("受保护音轨不能使用系统音频适配") }
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      guard tracks.count == 1, let track = tracks.first else { throw SystemAudioWaveIneligible.unsupported("多音轨保留原处理") }
      let formats = try await track.load(.formatDescriptions)
      guard (1...32).contains(formats.count), let format = formats.first,
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
        asbd.mFormatID == kAudioFormatMPEG4AAC, asbd.mSampleRate.isFinite,
        asbd.mSampleRate.rounded() == asbd.mSampleRate, (8000...192000).contains(asbd.mSampleRate) else {
        throw SystemAudioWaveIneligible.unsupported("此编码或格式变更保留原音轨")
      }
      // Independently encoded edits may carry separate but equivalent format
      // descriptions. Validate their decoded layout rather than their count.
      for description in formats {
        guard let value = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
          value.mFormatID == asbd.mFormatID, value.mSampleRate == asbd.mSampleRate,
          value.mChannelsPerFrame == asbd.mChannelsPerFrame else {
          throw SystemAudioWaveIneligible.unsupported("音轨包含编码、采样率或声道变化，保留原处理")
        }
      }
      let duration = try await asset.load(.duration), range = try await track.load(.timeRange)
      let segments = try await track.load(.segments)
      guard segments.count <= 4096 else { throw SystemAudioWaveIneligible.unsupported("音轨编辑表超出检查范围") }
      if requireEdits && segments.count <= 1 { throw SystemAudioWaveIneligible.unedited }
      guard duration.isNumeric, duration.seconds > 0, duration.seconds <= 86400,
        range.start.isNumeric, abs(range.start.seconds) <= 1 / asbd.mSampleRate,
        abs(range.duration.seconds - duration.seconds) <= 1 / asbd.mSampleRate,
        !segments.contains(where: \.isEmpty) else { throw SystemAudioWaveIneligible.unsupported("音轨的空白或时长映射保留原处理") }
      guard (1...2).contains(asbd.mChannelsPerFrame) else { throw SystemAudioWaveIneligible.unsupported("多声道保留原音轨，不混成立体声") }
      let frames = CMTimeConvertScale(duration, timescale: Int32(asbd.mSampleRate), method: .roundHalfAwayFromZero).value
      let wave = try FloatAudioWave(sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame), frames: frames)
      try Task.checkCancellation()
      guard start <= duration.seconds else { throw MTVError.message("保存的位置超过当前音轨时长，请选择从头播放") }
      guard try stamp(file, access: access) == identity else { throw MTVError.message("音轨文件在准备期间发生变化") }
      return SystemAudioWaveSource(file: file, asset: asset, track: track, wave: wave, identity: identity,
        startFrame: Int64((start * asbd.mSampleRate).rounded()), access: access)
    }, onCancel: { asset.cancelLoading() })
  }
  private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
  func readSize(offset: Int, remaining: Int) -> Int {
    let count = min(maximumReadBytes, remaining)
    if offset < wave.header.count { return min(count, wave.header.count - offset) }
    // End intermediate chunks on a whole frame. Do not splice half a Float32
    // sample from one decoder run with half from another decoder run.
    let remainder = (offset - wave.header.count + count) % wave.bytesPerFrame
    return count > remainder ? count - remainder : count
  }
  func read(offset: Int, count: Int, consumer: UUID) async throws -> Data {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
    let plan = try wave.readPlan(offset: offset, count: count)
    if plan.frameCount > 0 {
      try await budget.allow(throughFrame: plan.firstFrame + Int64(plan.frameCount), consumer: consumer)
    }
    try Task.checkCancellation()
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do { continuation.resume(returning: try decode(plan)) }
        catch {
          if !(error is CancellationError) { lock.lock(); failure = error.localizedDescription; lock.unlock() }
          continuation.resume(throwing: error)
        }
      }
    }
    try Task.checkCancellation()
    return data
  }
  private func decode(_ plan: FloatAudioWave.ReadPlan) throws -> Data {
    guard !isClosed else { throw CancellationError() }
    guard try Self.stamp(file, access: access) == identity else { throw MTVError.message("音轨文件已变化，请重新打开") }
    guard plan.frameCount > 0 else { return plan.header }
    let reader = try AVAssetReader(asset: asset), rate = Int32(wave.sampleRate)
    reader.timeRange = CMTimeRange(start: CMTime(value: plan.firstFrame, timescale: rate),
      duration: CMTime(value: Int64(plan.frameCount), timescale: rate))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: wave.sampleRate, AVNumberOfChannelsKey: wave.channels, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    defer { if reader.status == .reading { reader.cancelReading() } }
    let end = plan.firstFrame + Int64(plan.frameCount)
    var pcm = Data(), next = plan.firstFrame
    while let sample = output.copyNextSampleBuffer() {
      guard !isClosed else { throw CancellationError() }
      guard let block = CMSampleBufferGetDataBuffer(sample), let description = CMSampleBufferGetFormatDescription(sample),
        let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
        format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == Double(wave.sampleRate),
        format.mChannelsPerFrame == wave.channels, format.mBitsPerChannel == 32,
        format.mBytesPerFrame == wave.bytesPerFrame, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        format.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0 else {
        throw MTVError.message("系统返回的音频格式与请求不一致")
      }
      let time = CMSampleBufferGetPresentationTimeStamp(sample), size = CMBlockBufferGetDataLength(block)
      guard time.isNumeric, size > 0, size <= 1_048_576, size % wave.bytesPerFrame == 0,
        CMSampleBufferGetNumSamples(sample) == size / wave.bytesPerFrame else { throw CocoaError(.fileReadCorruptFile) }
      let converted = CMTimeConvertScale(time, timescale: rate, method: .roundHalfAwayFromZero)
      guard converted.isNumeric, converted.value >= -Int64(wave.sampleRate) * 2,
        converted.value <= wave.frames else { throw MTVError.message("音轨采样时间超出检查范围") }
      let position = converted.value
      let lower = max(plan.firstFrame, position), upper = min(end, position + Int64(size / wave.bytesPerFrame))
      guard lower <= next else { throw MTVError.message("系统音轨时间线出现缺口") }
      if upper > next {
        let count = Int(upper - next) * wave.bytesPerFrame, old = pcm.count
        guard old + count <= plan.frameCount * wave.bytesPerFrame else { throw CocoaError(.fileReadTooLarge) }
        pcm.count += count
        let status = pcm.withUnsafeMutableBytes { buffer in
          CMBlockBufferCopyDataBytes(block, atOffset: Int(next - position) * wave.bytesPerFrame,
            dataLength: count, destination: buffer.baseAddress!.advanced(by: old))
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        next = upper
      }
    }
    guard reader.status == .completed, next == end else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    guard !isClosed else { throw CancellationError() }
    guard try Self.stamp(file, access: access) == identity else { throw MTVError.message("音轨文件在读取期间发生变化") }
    reads += 1; largestReadFrames = max(largestReadFrames, plan.frameCount)
    var data = plan.header
    data.append(pcm.subdata(in: plan.leadingPCMBytes..<(plan.leadingPCMBytes + plan.pcmByteCount)))
    return data
  }
  func releaseConsumer(_ consumer: UUID) { Task { await budget.release(consumer) } }
  func cancel() {
    lock.lock(); closed = true; lock.unlock()
    Task { await budget.cancel() }
  }
  var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return failure }
  func statistics() async -> [String: Int] {
    await withCheckedContinuation { continuation in queue.async { [self] in
      continuation.resume(returning: ["reads": reads, "maximumReadFrames": largestReadFrames])
    } }
  }
}

import Foundation

public struct FragmentedMediaSegment: Equatable, Sendable {
  public let offset: Int64
  public let length: Int
  public let duration: Double
}

public struct FragmentedMediaIndex: Sendable {
  public let initialization: Data
  public let segments: [FragmentedMediaSegment]
  public let codec: String
  public let duration: Double
  public let bandwidth: Int

  public static func parse(_ prefix: Data, totalLength: Int64) throws -> Self {
    let bytes = Array(prefix.prefix(1_048_576))
    struct Box { let type: String; let start: Int; let body: Int; let end: Int }
    func fail() -> MTVError { .message("分片初始化或索引不符合当前支持的自包含 AVC/AAC 格式") }
    func read(_ at: Int, _ width: Int) throws -> UInt64 {
      guard at >= 0, width > 0, width <= 8, at <= bytes.count - width else { throw fail() }
      return bytes[at..<at + width].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    func boxes(_ start: Int, _ end: Int, top: Bool = false) throws -> [Box] {
      var result: [Box] = []; var at = start
      while at + 8 <= end {
        guard result.count < 256, let type = String(bytes: bytes[at + 4..<at + 8], encoding: .ascii) else { throw fail() }
        if top && ["moof", "mdat"].contains(type) { break }
        var size = try read(at, 4); var header = 8
        if size == 1 { size = try read(at + 8, 8); header = 16 }
        guard size >= UInt64(header), size <= UInt64(end - at) else { throw fail() }
        result.append(Box(type: type, start: at, body: at + header, end: at + Int(size)))
        at += Int(size)
      }
      if !top && at != end { throw fail() }
      return result
    }
    func one(_ values: [Box], _ name: String) throws -> Box {
      let matches = values.filter { $0.type == name }; guard matches.count == 1 else { throw fail() }; return matches[0]
    }
    let top = try boxes(0, bytes.count, top: true)
    guard let ftyp = top.first, ftyp.type == "ftyp", ftyp.body == 8, ftyp.end >= 16, totalLength > 0 else { throw fail() }
    let moov = try one(top, "moov"), sidx = try one(top, "sidx")
    guard sidx.start >= moov.end else { throw fail() }
    let movie = try boxes(moov.body, moov.end)
    _ = try one(movie, "mvex")
    let mvhd = try one(movie, "mvhd"), track = try one(movie, "trak")
    let children = try boxes(track.body, track.end)
    let tkhd = try one(children, "tkhd"), mdia = try one(children, "mdia")
    let media = try boxes(mdia.body, mdia.end), minf = try one(media, "minf")
    let minfBoxes = try boxes(minf.body, minf.end), stbl = try one(minfBoxes, "stbl")
    let dinf = try one(minfBoxes, "dinf"), dataInformation = try boxes(dinf.body, dinf.end)
    let dref = try one(dataInformation, "dref")
    guard dref.body + 8 <= dref.end, try read(dref.body + 4, 4) == 1 else { throw fail() }
    let references = try boxes(dref.body + 8, dref.end), reference = try one(references, "url ")
    guard references.count == 1, reference.body + 4 == reference.end, try read(reference.body, 4) == 1 else { throw fail() }
    let table = try boxes(stbl.body, stbl.end), stsd = try one(table, "stsd")
    guard try read(stsd.body + 4, 4) == 1, stsd.body + 16 <= stsd.end,
      let codec = String(bytes: bytes[stsd.body + 12..<stsd.body + 16], encoding: .ascii),
      ["avc1", "avc3", "mp4a"].contains(codec) else { throw fail() }
    let version = try read(sidx.body, 1), timescale = try read(sidx.body + 8, 4)
    guard version <= 1, timescale > 0 else { throw fail() }
    let width = version == 0 ? 4 : 8
    let first = try read(sidx.body + 12 + width, width)
    let countAt = sidx.body + 12 + width * 2 + 2
    let count = try read(countAt, 2)
    guard count > 0, count <= 8192, countAt + 2 + Int(count) * 12 <= sidx.end,
      first <= UInt64(Int64.max - Int64(sidx.end)) else { throw fail() }
    var offset = Int64(sidx.end) + Int64(first)
    var segments: [FragmentedMediaSegment] = []
    for index in 0..<Int(count) {
      let at = countAt + 2 + index * 12
      let reference = try read(at, 4), ticks = try read(at + 4, 4)
      let length = Int(reference & 0x7fff_ffff), seconds = Double(ticks) / Double(timescale)
      guard reference & 0x8000_0000 == 0, length > 0, length <= 33_554_432,
        seconds > 0, seconds.isFinite, seconds <= 120, offset >= 0,
        offset <= totalLength - Int64(length) else { throw fail() }
      segments.append(FragmentedMediaSegment(offset: offset, length: length, duration: seconds))
      offset += Int64(length)
    }
    // The first fragment must use movie-fragment-relative addressing, not offsets into the original file.
    let start = Int(segments[0].offset)
    guard start <= bytes.count - 8, try read(start + 4, 4) == 0x6d6f6f66 else { throw fail() }
    let fragmentSize = try read(start, 4)
    guard fragmentSize >= 8, fragmentSize <= UInt64(bytes.count - start) else { throw fail() }
    let fragment = try boxes(start + 8, start + Int(fragmentSize))
    let traf = try one(fragment, "traf"), trafBoxes = try boxes(traf.body, traf.end)
    let tfhd = try one(trafBoxes, "tfhd")
    guard try read(tfhd.body, 4) & 0x020001 == 0x020000 else { throw fail() }

    // HLS requires zero movie/track durations in its initialization. No compressed samples are changed.
    var initialization = Data(bytes[0..<moov.end])
    for (box, trackHeader) in [(mvhd, false), (tkhd, true)] {
      let version = try read(box.body, 1); guard version <= 1 else { throw fail() }
      let position = box.body + (trackHeader ? (version == 0 ? 20 : 28) : (version == 0 ? 16 : 24))
      let size = version == 0 ? 4 : 8
      guard position + size <= box.end else { throw fail() }
      initialization.replaceSubrange(position..<position + size, with: repeatElement(UInt8(0), count: size))
    }
    // Advertise the ISO6 fragmented profile supported by the validated AVC/AAC initialization.
    initialization.replaceSubrange(8..<12, with: Data("iso6".utf8))
    let duration = segments.reduce(0) { $0 + $1.duration }
    let bandwidth = Int(ceil(segments.map { Double($0.length) * 8 / $0.duration }.max()! * 1.1))
    return Self(initialization: initialization, segments: segments, codec: codec, duration: duration, bandwidth: bandwidth)
  }

  public func playlist(prefix: String) throws -> String {
    guard prefix.range(of: #"^/[a-f0-9-]+/[va]$"#, options: .regularExpression) != nil else { throw MTVError.message("无效的内部播放列表路径") }
    let target = Int(ceil(segments.map(\.duration).max() ?? 1))
    var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MAP:URI=\"\(prefix)/init.mp4\""]
    for (index, segment) in segments.enumerated() {
      lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
      lines.append("\(prefix)/\(index).m4s")
    }
    lines.append("#EXT-X-ENDLIST")
    return lines.joined(separator: "\n") + "\n"
  }
}

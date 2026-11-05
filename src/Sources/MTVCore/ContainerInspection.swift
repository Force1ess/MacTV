import Foundation

public enum ContainerInspection {
  /// Bounded Matroska Tracks/BlockAdditionMapping inspection, never a byte-string search.
  public static func dolbyVisionProfile(_ data: Data) -> Int? {
    guard matroskaHeader(data) else { return nil }
    let bytes = Array(data.prefix(262144))
    struct Element { let id: UInt64; let start: Int; let end: Int }
    func integer(_ offset: Int, id: Bool) -> (UInt64,Int)? {
      guard offset < bytes.count, bytes[offset] != 0 else { return nil }
      var marker: UInt8 = 128, count = 1
      while bytes[offset] & marker == 0 { marker >>= 1; count += 1 }
      guard count <= (id ? 4:8), offset + count <= bytes.count else { return nil }
      var value = UInt64(id ? bytes[offset]:bytes[offset] & (marker - 1))
      for index in 1..<count { value = (value << 8) | UInt64(bytes[offset + index]) }
      return (value,count)
    }
    func children(_ start: Int, _ end: Int, partialTail: Bool = false) -> [Element] {
      var cursor = start, elements: [Element] = []
      while cursor < end, elements.count < 512 {
        guard let (id,width) = integer(cursor,id:true), let (size,sizeWidth) = integer(cursor + width,id:false) else { return partialTail ? elements:[] }
        let body = cursor + width + sizeWidth
        guard body <= end else { return partialTail ? elements:[] }
        if id == 0x1f43b675 { break } // Never inspect video Clusters as metadata.
        guard size <= UInt64(end - body) || id == 0x18538067 else { return partialTail ? elements:[] }
        let stop = body + Int(min(size,UInt64(end - body)))
        elements.append(Element(id:id,start:body,end:stop)); cursor = stop
      }
      return elements
    }
    let roots = children(0,bytes.count)
    guard let segment = roots.first(where:{$0.id == 0x18538067}),
      let tracks = children(segment.start,segment.end,partialTail:true).first(where:{$0.id == 0x1654ae6b}) else { return nil }
    for track in children(tracks.start,tracks.end) where track.id == 0xae {
      let fields = children(track.start,track.end)
      guard let type = fields.first(where:{$0.id == 0x83}), type.end - type.start == 1, bytes[type.start] == 1,
        let codec = fields.first(where:{$0.id == 0x86}),
        String(bytes:bytes[codec.start..<codec.end],encoding:.ascii) == "V_MPEGH/ISO/HEVC" else { continue }
      for mapping in fields where mapping.id == 0x41e4 {
        let fields = children(mapping.start,mapping.end)
        guard let kind = fields.first(where:{$0.id == 0x41e7}),
          ["dvcC","dvvC"].contains(String(bytes:bytes[kind.start..<kind.end],encoding:.ascii) ?? ""),
          let config = fields.first(where:{$0.id == 0x41ed}), (4...32).contains(config.end - config.start),
          bytes[config.start] == 1, bytes[config.start + 3] & 4 != 0 else { continue }
        return Int(bytes[config.start + 2] >> 1)
      }
    }
    return nil
  }
  /// Reads only the bounded EBML header. A filename extension is not evidence.
  public static func matroskaHeader(_ data: Data) -> Bool {
    let bytes = Array(data.prefix(4096))
    guard bytes.count >= 5, Array(bytes.prefix(4)) == [0x1a, 0x45, 0xdf, 0xa3] else { return false }
    func variable(_ start: Int, keepMarker: Bool) -> (UInt64, Int)? {
      guard start < bytes.count, bytes[start] != 0 else { return nil }
      var marker: UInt8 = 0x80
      var length = 1
      while bytes[start] & marker == 0 {
        marker >>= 1
        length += 1
      }
      guard length <= 8, start + length <= bytes.count else { return nil }
      var value = UInt64(keepMarker ? bytes[start] : bytes[start] & (marker - 1))
      for offset in 1..<length { value = (value << 8) | UInt64(bytes[start + offset]) }
      return (value, length)
    }
    guard let (size, width) = variable(4, keepMarker: false),
      size <= UInt64(bytes.count - 4 - width)
    else { return false }
    var offset = 4 + width
    let end = offset + Int(size)
    while offset < end {
      guard let (id, idWidth) = variable(offset, keepMarker: true), idWidth <= 4,
        let (length, sizeWidth) = variable(offset + idWidth, keepMarker: false)
      else { return false }
      offset += idWidth + sizeWidth
      guard offset <= end, length <= UInt64(end - offset) else { return false }
      if id == 0x4282 {
        let value = Array(bytes[offset..<(offset + Int(length))])
        let text = value.prefix { $0 != 0 }
        return String(bytes: text, encoding: .ascii) == "matroska"
          && value.dropFirst(text.count).allSatisfy { $0 == 0 }
      }
      offset += Int(length)
    }
    return false
  }
}

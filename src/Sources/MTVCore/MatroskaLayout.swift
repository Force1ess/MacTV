import Foundation

/// Bounded structural diagnostics. Exposes element IDs, sizes and positions,
/// excluding attachment bytes, titles and other user metadata.
public struct MatroskaLayout: Codable, Sendable {
  public struct Element: Codable, Sendable {
    public let id: String
    public let name: String
    public let offset: UInt64
    public let size: UInt64?
  }
  public let leadingElements: [Element]
  public let seekTargets: [Element]
  private static let names: [UInt64:String] = [0x1a45dfa3:"EBML",0x18538067:"Segment",0x114d9b74:"SeekHead",
    0x1549a966:"Info",0x1654ae6b:"Tracks",0x1f43b675:"Cluster",0x1c53bb6b:"Cues",0x1941a469:"Attachments",
    0x1043a770:"Chapters",0x1254c367:"Tags",0xec:"Void"]
  private struct Header { let id:UInt64, size:UInt64?, payload:Int, end:Int? }
  private static func integer(_ bytes:[UInt8],_ start:Int,marker:Bool) -> (UInt64,Int)? {
    guard bytes.indices.contains(start), bytes[start] != 0 else { return nil }
    var bit:UInt8=0x80, width=1
    while bytes[start]&bit == 0 { bit >>= 1; width += 1 }
    guard width<=8, start<=bytes.count-width else { return nil }
    var value=UInt64(marker ? bytes[start]:bytes[start] & (bit-1))
    for index in 1..<width { value=(value<<8)|UInt64(bytes[start+index]) }
    return (value,width)
  }
  private static func header(_ bytes:[UInt8],_ start:Int) -> Header? {
    guard let (id,idWidth)=integer(bytes,start,marker:true), idWidth<=4,
      let (size,sizeWidth)=integer(bytes,start+idWidth,marker:false) else { return nil }
    let payload=start+idWidth+sizeWidth
    let unknown=size == (UInt64(1) << (7*sizeWidth))-1
    let end = !unknown && size<=UInt64(bytes.count-payload) ? payload+Int(size):nil
    return Header(id:id,size:unknown ? nil:size,payload:payload,end:end)
  }
  private static func element(_ value:Header,_ offset:UInt64) -> Element {
    Element(id:String(value.id,radix:16),name:names[value.id] ?? "Other",offset:offset,size:value.size)
  }
  public static func elementHeader(_ data:Data,offset:UInt64) -> Element? {
    header(Array(data.prefix(4096)),0).map { element($0,offset) }
  }
  public static func inspect(_ data:Data,fileLength:UInt64) -> Self? {
    guard ContainerInspection.matroskaHeader(data) else { return nil }
    let bytes=Array(data.prefix(4096))
    guard let ebml=header(bytes,0), let afterEBML=ebml.end,
      let segment=header(bytes,afterEBML), segment.id==0x18538067 else { return nil }
    var elements=[element(ebml,0),element(segment,UInt64(afterEBML))], targets:[Element]=[]
    var cursor=segment.payload
    while elements.count<32, let current=header(bytes,cursor) {
      elements.append(element(current,UInt64(cursor)))
      if current.id==0x114d9b74, let end=current.end {
        var seek=current.payload
        while seek<end, targets.count<32, let item=header(bytes,seek), let itemEnd=item.end, itemEnd<=end {
          if item.id==0x4dbb {
            var field=item.payload, targetID:UInt64?, position:UInt64?
            while field<itemEnd, let value=header(bytes,field), let valueEnd=value.end, valueEnd<=itemEnd {
              if (1...8).contains(valueEnd-value.payload) {
                let number=bytes[value.payload..<valueEnd].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
                if value.id==0x53ab { targetID=number }
                if value.id==0x53ac { position=number }
              }
              field=valueEnd
            }
            if let targetID, let position {
              let absolute=UInt64(segment.payload).addingReportingOverflow(position)
              if !absolute.overflow, absolute.partialValue<fileLength {
                targets.append(Element(id:String(targetID,radix:16),name:names[targetID] ?? "Other",offset:absolute.partialValue,size:nil))
              }
            }
          }
          seek=itemEnd
        }
      }
      guard let end=current.end, end>cursor else { break }; cursor=end
    }
    return Self(leadingElements:elements,seekTargets:targets)
  }
}

import Foundation

/// Converts a first-party provider page into credential-free plugin metadata.
/// Provider preview URLs stay in the native result and never enter Gallery JS.
public struct CloudPhotoPage {
  public let items: [MediaItem]
  public let next: String?
  public let previews: [String: URL]
  public init(data: Data, requester: String) throws {
    guard data.count <= 2_000_000, let page = try JSONSerialization.jsonObject(with:data) as? [String:Any],
      page["requiresLogin"] as? Bool != true else { throw MTVError.message(L("Sign in to Quark Drive in Settings before opening cloud photos.")) }
    guard let rows = page["items"] as? [[String:Any]], rows.count <= 200 else { throw MTVError.message("Invalid cloud-photo page") }
    var items: [MediaItem] = [], previews: [String:URL] = [:]
    for row in rows {
      guard let fid = row["reference"] as? String, Self.validID(fid),
        let name = row["title"] as? String, !name.isEmpty, name.utf8.count <= 2048,
        let rawKind = row["kind"] as? String, ["folder","photo"].contains(rawKind),
        row["url"] == nil, row["poster"] == nil else { throw MTVError.message("Invalid cloud-photo item") }
      let reference = "quark:" + fid
      items.append(MediaItem(id:reference,title:name,subtitle:row["subtitle"] as? String ?? "",source:requester,
        reference:reference,kind:rawKind == "folder" ? .folder:.photo))
      if rawKind == "photo", let preview = row["preview"] as? String, let url = URL(string:preview),
        NetworkPolicy.permitsPlayback(url,domains:["quark.cn"]) { previews[fid] = url }
    }
    if let next = page["next"] as? String {
      guard let number = Int(next), (1...2000).contains(number) else { throw MTVError.message("Invalid cloud-photo cursor") }
      self.next = next
    } else { next = nil }
    self.items = items; self.previews = previews
  }
  public static func validID(_ value: String) -> Bool {
    value.range(of:#"^[A-Za-z0-9_-]{1,128}$"#,options:.regularExpression) != nil
  }
  public func encoded() throws -> Data {
    var object: [String:Any] = ["items":try JSONSerialization.jsonObject(with:JSONEncoder().encode(items))]
    if let next { object["next"] = next }
    return try JSONSerialization.data(withJSONObject:object)
  }
}

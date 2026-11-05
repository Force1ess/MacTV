import Foundation
import MTVCore

enum CloudPhotoFailure: Error { case mediaApprovalRequired(String) }

/// Composes the existing Quark adapter natively. Gallery never receives its
/// session, original-file URLs or preview URL query parameters.
actor CloudPhotos {
  static let shared = CloudPhotos()
  private struct Entry: Sendable { let owner: String, fid: String, preview: URL?, account: String }
  private var entries: [String:Entry] = [:]
  private var references: [String:String] = [:]
  private var epoch = UUID()
  private var ownerEpochs: [String:UUID] = [:]
  private var originalReads = 0, previewReads = 0, decodedPreviews = 0
  private var previewFailures = 0, lastPreviewHTTPStatus = 0, originalPreviewFallbacks = 0
  private let previewGate = AsyncWorkGate(limit:2)
  private let cache = NSCache<NSString,NSData>()
  private init() { cache.totalCostLimit = 32_000_000 }
  func revoke() { epoch = UUID(); ownerEpochs.removeAll(); entries.removeAll(); references.removeAll(); cache.removeAllObjects() }
  func release(owner: String) {
    ownerEpochs[owner] = UUID()
    for (token,entry) in entries where entry.owner == owner {
      cache.removeObject(forKey:"original:\(token):\(entry.account)" as NSString)
      cache.removeObject(forKey:"thumbnail:\(token):\(entry.account)" as NSString)
    }
    entries = entries.filter { $0.value.owner != owner }
    references = references.filter { !$0.key.hasPrefix(owner+":") }
  }
  func statistics() -> [String:Int] { ["registeredImages":entries.count,"originalReads":originalReads,"previewReads":previewReads,"decodedPreviews":decodedPreviews,"previewFailures":previewFailures,"lastPreviewHTTPStatus":lastPreviewHTTPStatus,"originalPreviewFallbacks":originalPreviewFallbacks] }
  func noteDecodedPreview() { decodedPreviews += 1 }
  private func provider() throws -> PluginRecord {
    guard let plugin = try PluginCatalog.load(root:PluginClient.root).plugins.first(where:{$0.id == "mtv.quark"}) else {
      throw MTVError.message("Quark Drive is not installed.")
    }
    return plugin
  }
  private func session(_ plugin: PluginRecord) throws -> PluginSession {
    guard let session = try PluginSessionStore().load(pluginID:plugin.id) else {
      throw MTVError.message(L("Sign in to Quark Drive in Settings before opening cloud photos."))
    }
    try session.validate(for:plugin.manifest); return session
  }
  private func identity(_ session: PluginSession) -> String { session.authIdentity?.uuidString ?? "legacy-\(session.savedAt)" }
  func browse(requester: String, input: [String:String]) async throws -> Data {
    if input["entry"] == "true" {
      entries = entries.filter { $0.value.owner != requester }
      references = references.filter { !$0.key.hasPrefix(requester + ":") }
      let item = MediaItem(id:"quark:0",title:LT("夸克网盘"),source:requester,reference:"quark:0",kind:.folder)
      return try JSONSerialization.data(withJSONObject:["items":try JSONSerialization.jsonObject(with:JSONEncoder().encode([item]))])
    }
    let reference = input["reference"] ?? "quark:0"
    guard reference.hasPrefix("quark:") else { throw MTVError.message("Invalid cloud-photo folder") }
    let fid = String(reference.dropFirst(6))
    guard CloudPhotoPage.validID(fid) else { throw MTVError.message("Invalid cloud-photo folder") }
    let plugin = try provider(); let account = identity(try session(plugin)); let version = epoch
    let ownerVersion = ownerEpochs[requester]
    let data = try await PluginClient.execute(plugin,action:"browse",input:["folder":fid,"page":input["page"] ?? "1","media":"photos"])
    guard version == epoch, ownerEpochs[requester] == ownerVersion else { throw CancellationError() }
    guard identity(try session(plugin)) == account else { throw CancellationError() }
    let page = try CloudPhotoPage(data:data,requester:requester)
    if let query = input["query"], !query.isEmpty {
      guard query.count <= 200 else { throw MTVError.message("Cloud-photo search is too long") }
      // Filtering must preserve the provider cursor, including empty pages.
      let matches = page.items.filter { $0.title.localizedCaseInsensitiveContains(query) }
      var filtered: [String:Any] = ["items":try JSONSerialization.jsonObject(with:JSONEncoder().encode(matches))]
      if let next = page.next { filtered["next"] = next }
      try register(page,owner:requester,account:account)
      return try JSONSerialization.data(withJSONObject:filtered)
    }
    try register(page,owner:requester,account:account)
    return try page.encoded()
  }
  private func register(_ page: CloudPhotoPage, owner: String, account: String) throws {
    guard entries.count + page.items.count <= 32_768 else { throw MTVError.message("Reopen Gallery to refresh this large cloud-photo session.") }
    for item in page.items where item.kind == .photo {
      guard let reference = item.reference else { continue }
      let fid = String(reference.dropFirst(6)), key = owner + ":" + fid
      let token = references[key] ?? UUID().uuidString.lowercased()
      references[key] = token; entries[token] = Entry(owner:owner,fid:fid,preview:page.previews[fid],account:account)
    }
  }
  func preview(owner: String, reference: String) -> String? {
    guard reference.hasPrefix("quark:"), let token = references[owner + ":" + reference.dropFirst(6)], entries[token] != nil else { return nil }
    return "mactv-cloud-photo://" + token
  }
  private func original(owner: String, reference: String) async throws -> RemotePlaybackRequest {
    guard reference.hasPrefix("quark:"), let token = references[owner + ":" + reference.dropFirst(6)],
      let entry = entries[token], entry.owner == owner else { throw MTVError.message("Cloud photo is no longer in this gallery.") }
    let plugin = try provider()
    guard identity(try session(plugin)) == entry.account else { throw MTVError.message("Reopen Gallery after changing the Quark account.") }
    let data = try await PluginClient.execute(plugin,action:"resolve",input:["reference":entry.fid,"original":"true","media":"photos"])
    guard entries[token]?.owner == owner else { throw CancellationError() }
    let descriptor = try JSONDecoder().decode(PlaybackDescriptor.self,from:data)
    guard descriptor.transport == "original-file", let url = URL(string:descriptor.url),
      let host = url.host, FirstPartyMediaScope.isQuarkPlaybackHost(host) else { throw MTVError.message("Invalid original cloud-photo response") }
    guard MediaSessionApprovalStore().permits(pluginID:plugin.id,host:host) else { throw CloudPhotoFailure.mediaApprovalRequired(host) }
    let request = try RemotePlaybackRequest(url:url,domains:plugin.manifest.playbackDomains ?? [],headers:descriptor.headers ?? [:],referer:plugin.manifest.playbackReferer)
    return try request.authorizingMediaSession(session(plugin),approvedHost:host,quarkPlaybackService:true)
  }
  func data(owner: String, reference: String) async throws -> Data {
    let version = epoch
    let account = identity(try session(provider()))
    guard let token = references[owner + ":" + reference.dropFirst(6)], entries[token]?.account == account else { throw CancellationError() }
    let key = "original:\(token):\(account)" as NSString
    if let data = cache.object(forKey:key) { return data as Data }
    let request = try await original(owner:owner,reference:reference)
    let data = try await read(request,maximum:15_000_000)
    guard version == epoch, entries[token]?.owner == owner else { throw CancellationError() }
    guard identity(try session(provider())) == account else { throw CancellationError() }
    originalReads += 1; cache.setObject(data as NSData,forKey:key,cost:data.count); return data
  }
  func thumbnail(_ url: URL) async throws -> Data {
    guard url.scheme == "mactv-cloud-photo", let token = url.host, let entry = entries[token] else { throw MTVError.message("Unknown cloud-photo preview") }
    let plugin = try provider(); let credential = try session(plugin)
    guard identity(credential) == entry.account else { throw CancellationError() }
    let version = epoch
    let key = "thumbnail:\(token):\(entry.account)" as NSString
    if let cached = cache.object(forKey:key) { return cached as Data }
    // No account headers are sent to thumbnail hosts. Signed URLs are native-only.
    guard let preview = entry.preview else {
      return try await previewGate.run { try await self.data(owner:entry.owner,reference:"quark:"+entry.fid) }
    }
    let request = try RemotePlaybackRequest(url:preview,domains:["quark.cn"],headers:[:],referer:nil)
    let data: Data
    do { data = try await previewGate.run { try await self.read(request,maximum:2_000_000) } }
    catch {
      if !(error is CancellationError) {
        previewFailures += 1
        lastPreviewHTTPStatus = (error as? RemoteImageResponseError)?.status ?? 0
      }
      if let response = error as? RemoteImageResponseError,
        response.permitsOriginalPreview, version == epoch, entries[token]?.owner == entry.owner,
        identity(try session(plugin)) == entry.account {
        // A denied or expired optional rendition must not prevent displaying an
        // otherwise accessible photo. Never send account cookies to its CDN.
        // Disable that rendition for this account-bound gallery registration.
        entries[token] = Entry(owner:entry.owner,fid:entry.fid,preview:nil,account:entry.account)
        originalPreviewFallbacks += 1
        return try await previewGate.run { try await self.data(owner:entry.owner,reference:"quark:"+entry.fid) }
      }
      throw error
    }
    guard version == epoch, entries[token]?.owner == entry.owner else { throw CancellationError() }
    guard identity(try session(plugin)) == entry.account else { throw CancellationError() }
    previewReads += 1; cache.setObject(data as NSData,forKey:key,cost:data.count); return data
  }
  private func read(_ request: RemotePlaybackRequest, maximum: Int) async throws -> Data {
    try await RemoteImageReader(request:request,maximum:maximum).read()
  }
}

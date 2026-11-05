import Foundation
import CryptoKit

public final class NativeLibraryCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?
  private var callbacks: [UUID:@Sendable () -> Void] = [:]
  public init() {}
  func start(_ process: Process) throws {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    try process.run(); self.process = process
  }
  public func cancel() {
    lock.lock(); cancelled = true; let process = process, wake=Array(callbacks.values); callbacks.removeAll(); lock.unlock()
    for callback in wake { callback() }
    if let process, process.isRunning { process.terminate() }
  }
  func register(_ callback: @escaping @Sendable () -> Void) -> UUID? {
    lock.lock()
    if cancelled { lock.unlock(); callback(); return nil }
    let id=UUID(); callbacks[id]=callback; lock.unlock(); return id
  }
  func remove(_ id: UUID) { lock.lock(); callbacks.removeValue(forKey:id); lock.unlock() }
  func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
}

private final class NativeLibraryReply: @unchecked Sendable {
  private let lock=NSLock()
  private var continuation: CheckedContinuation<Data,Error>?
  init(_ continuation: CheckedContinuation<Data,Error>) { self.continuation=continuation }
  func finish(_ result: Result<Data,Error>) {
    lock.lock(); let continuation=continuation; self.continuation=nil; lock.unlock()
    continuation?.resume(with:result)
  }
}

enum NativeLibraryWork {
  private static let queue: OperationQueue = {
    let queue=OperationQueue(); queue.name="MacTV scoped resource reads"; queue.maxConcurrentOperationCount=4; return queue
  }()
  static func run(cancellation: NativeLibraryCancellation, operation: @escaping @Sendable () throws -> Data) async throws -> Data {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        let reply=NativeLibraryReply(continuation)
        guard let id=cancellation.register({ reply.finish(.failure(CancellationError())) }) else { return }
        queue.addOperation {
          defer { cancellation.remove(id) }
          do { try cancellation.check(); let data=try operation(); try cancellation.check(); reply.finish(.success(data)) }
          catch { reply.finish(.failure(error)) }
        }
      }
    },onCancel:{ cancellation.cancel() })
  }
}

/// Native services shared by optional content plugins. Scripts receive media
/// metadata and opaque references, never unrestricted filesystem access.
public final class NativeLibrary: @unchecked Sendable {
  public static let shared = NativeLibrary()
  private let lock = NSRecursiveLock()
  private var roots: [String: [URL]] = [:]
  private var shares: [String: MountedSMBShare] = [:]
  private var failures: [String:String] = [:]
  private var leases: [String:UUID] = [:]
  private let musicLock = NSLock()
  private var musicRows: MusicLibraryCatalog?
  private var musicReadAt = Date.distantPast
  private var musicURLs: [String: URL] = [:]
  public func requestAsync(pluginID: String, services: [String], service: String, input: [String:String], cancellation: NativeLibraryCancellation) async throws -> Data {
    try await NativeLibraryWork.run(cancellation:cancellation) { [self] in
      try request(pluginID:pluginID,services:services,service:service,input:input,cancellation:cancellation)
    }
  }
  public func configure(pluginID: String, roots: [URL], share: MountedSMBShare? = nil) throws {
    let canonicalRoots = try Array(roots.filter(\.isFileURL).prefix(32)).map { URL(fileURLWithPath:try ScopedFileReader.canonicalPath($0)) }
    lock.lock(); defer { lock.unlock() }
    self.roots[pluginID] = canonicalRoots
    leases[pluginID]=UUID()
    shares[pluginID] = share
    failures[pluginID] = nil
  }
  public func markUnavailable(pluginID: String, message: String) {
    lock.lock(); defer { lock.unlock() }; roots[pluginID] = []; shares[pluginID] = nil; failures[pluginID] = message; leases[pluginID]=UUID()
  }
  public func release(pluginID: String) {
    lock.lock(); defer { lock.unlock() }
    roots.removeValue(forKey:pluginID); shares.removeValue(forKey:pluginID); failures.removeValue(forKey:pluginID)
    leases[pluginID]=UUID()
    musicURLs = musicURLs.filter { !$0.key.hasPrefix(pluginID+":") }
  }
  public func request(pluginID: String, services: [String], service: String, input: [String: String], cancellation: NativeLibraryCancellation = NativeLibraryCancellation()) throws -> Data {
    try cancellation.check()
    lock.lock(); let lease=leases[pluginID]; lock.unlock()
    guard services.contains(service) else { throw MTVError.message("Native library service was not declared") }
    let query = input["query"] ?? ""
    guard query.count <= 200, let offset = Int(input["page"] ?? "0"), offset >= 0 else { throw MTVError.message("Invalid library page") }
    let items: [MediaItem]
    switch service {
    case "pictures":
      lock.lock(); let selectedRoots = roots[pluginID] ?? [], share = shares[pluginID], failure = failures[pluginID]; lock.unlock()
      if let failure {
        guard input["reference"]?.isEmpty != false else { throw MTVError.message(failure) }
        items = [MediaItem(id:"local-unavailable",title:LT("影片来源"),subtitle:failure,source:pluginID,reference:"unavailable",kind:.folder)]
      } else {
        try share?.validateCurrentMount()
        items = try pictures(pluginID:pluginID, roots:selectedRoots, reference:input["reference"])
        try share?.validateCurrentMount()
      }
    case "music": items = try tracks(pluginID: pluginID, input:input, cancellation:cancellation,lease:lease)
    default: throw MTVError.message("Unknown native library service")
    }
    lock.lock(); let valid=leases[pluginID]==lease; lock.unlock()
    guard valid else { throw CancellationError() }; try cancellation.check()
    let filtered = items.filter { query.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
    let page = Array(filtered.dropFirst(offset).prefix(100))
    var result: [String: Any] = ["items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))]
    if offset + page.count < filtered.count { result["next"] = String(offset + page.count) }
    return try JSONSerialization.data(withJSONObject: result)
  }
  public func asset(pluginID: String, services: [String], reference: String, kind: MediaKind) throws -> URL {
    lock.lock(); let selectedRoots = roots[pluginID] ?? [], share = shares[pluginID], musicURL = musicURLs[pluginID + ":" + reference]; lock.unlock()
    try share?.validateCurrentMount()
    if kind == .audio, services.contains("music"), let url = musicURL { return url }
    guard kind == .photo, services.contains("pictures") else { throw MTVError.message("Media is outside the declared native library") }
    let url = try pictureURL(roots:selectedRoots, reference:reference)
    let info = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard info.isRegularFile == true, Self.imageExtensions.contains(url.pathExtension.lowercased()) else { throw MTVError.message("Not an image in this library") }
    return url
  }
  public func fileAccess(pluginID: String, reference: String, url: URL) -> ScopedFileAccess {
    lock.lock(); defer { lock.unlock() }
    if let share = shares[pluginID] { return .verifiedSMB(share) }
    if let index = Int(reference.split(separator:":",maxSplits:1).first ?? ""), let roots = roots[pluginID], roots.indices.contains(index) { return .within(roots[index]) }
    return .within(url.deletingLastPathComponent())
  }
  private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif"]
  private func pictureURL(roots: [URL], reference: String) throws -> URL {
    let parts = reference.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let index = Int(parts[0]), index >= 0,
      roots.indices.contains(index), parts[1].utf8.count <= 8192,
      let data = Data(base64Encoded: String(parts[1])), let relative = String(data: data, encoding: .utf8),
      !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\0") else {
      throw MTVError.message("Invalid picture-library reference")
    }
    let root = roots[index]
    let candidate = relative.isEmpty ? root : root.appendingPathComponent(relative)
    let url = URL(fileURLWithPath:try ScopedFileReader.canonicalPath(candidate))
    guard url == root || url.path.hasPrefix(root.path + "/") else { throw MTVError.message("Picture path leaves the selected library") }
    return url
  }
  private func pictures(pluginID: String, roots: [URL], reference: String?) throws -> [MediaItem] {
    if reference == nil || reference == "" {
      return roots.enumerated().map { index, root in
        MediaItem(id:"root-\(index)", title:root.lastPathComponent, source:pluginID, reference:"\(index):", kind:.folder)
      }
    }
    let reference = reference!
    let directory = try pictureURL(roots:roots,reference:reference)
    let scope = Int(reference.split(separator:":",maxSplits:1)[0])!
    let root = roots[scope]
    let files = try FileManager.default.contentsOfDirectory(at:directory, includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isPackageKey],options:[.skipsHiddenFiles])
    guard files.count <= 50_000 else { throw MTVError.message("This folder is too large; choose a smaller album") }
    return try files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.compactMap { file in
      let info = try file.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isPackageKey])
      guard info.isPackage != true else { return nil }
      let resolved = URL(fileURLWithPath:try ScopedFileReader.canonicalPath(file))
      guard resolved.path.hasPrefix(root.path + "/") else { return nil }
      guard info.isDirectory == true || (info.isRegularFile == true && Self.imageExtensions.contains(file.pathExtension.lowercased())) else { return nil }
      let relative = resolved.path.dropFirst(root.path.count + 1)
      let ref = "\(scope):" + Data(relative.utf8).base64EncodedString()
      return MediaItem(id:SHA256.hash(data:Data(ref.utf8)).map { String(format:"%02x",$0) }.joined(), title:file.lastPathComponent, source:pluginID, reference:ref, kind:info.isDirectory == true ? .folder:.photo)
    }
  }
  private func readMusic(cancellation: NativeLibraryCancellation) throws -> MusicLibraryCatalog {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacTVMusicLibrary.app/Contents/MacOS/MacTVMusicLibrary")
    guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw MTVError.message("The native Music library reader is not installed.") }
    let process = Process(), output = Pipe()
    process.executableURL = executable; process.arguments = ["--read-local-library-v1"]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    process.environment = ["PATH":"/usr/bin:/bin"]
    try cancellation.start(process)
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline:.now()+12,execute:deadline)
    defer { deadline.cancel(); if process.isRunning { process.terminate() }; process.waitUntilExit(); try? output.fileHandleForReading.close() }
    var data = Data()
    while let chunk = try output.fileHandleForReading.read(upToCount:65_536), !chunk.isEmpty {
      guard data.count + chunk.count <= 5_000_000 else { throw MTVError.message("The Music library exceeds this preview's size limit.") }
      data.append(chunk)
    }
    process.waitUntilExit()
    try cancellation.check()
    guard process.terminationStatus == 0 else { throw MTVError.message("The Music library service did not respond or denied access. Open Music once to check its library, then try again.") }
    let response = try JSONDecoder().decode(MusicLibraryCatalog.self,from:data)
    guard response.schema == 1, response.items.count <= 50_000 else { throw MTVError.message("Invalid native Music library response") }
    return response
  }
  private func tracks(pluginID: String, input: [String:String], cancellation: NativeLibraryCancellation, lease: UUID?) throws -> [MediaItem] {
    musicLock.lock(); defer { musicLock.unlock() }
    try cancellation.check()
    if musicRows == nil || Date().timeIntervalSince(musicReadAt) > 30 {
      musicRows = try readMusic(cancellation:cancellation); musicReadAt = Date()
    }
    guard let catalog = musicRows else { throw MTVError.message("The Music library is unavailable.") }
    try cancellation.check()
    lock.lock(); defer { lock.unlock() }
    guard leases[pluginID]==lease else { throw CancellationError() }
    for row in catalog.items {
      guard row.id.range(of:#"^[0-9]{1,32}$"#,options:.regularExpression) != nil,
        let url = URL(string:row.location), url.isFileURL, url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, url.host == nil || url.host == "" || url.host == "localhost" else { continue }
      musicURLs[pluginID + ":" + row.id] = url
    }
    return try catalog.page(reference:input["reference"] ?? "",query:input["query"] ?? "",owner:pluginID)
  }
}

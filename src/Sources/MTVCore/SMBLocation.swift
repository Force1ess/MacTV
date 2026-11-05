import Foundation

public struct SMBLocation: Equatable {
  public let shareURL: URL
  public let subdirectory: [String]
  public init(_ text: String) throws {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let address = text.contains("://") ? text : "smb://" + text
    guard text.utf8.count <= 2048, !text.contains("\\"),
      text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
      var parts = URLComponents(string: address), parts.scheme?.lowercased() == "smb",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else {
      throw MTVError.message("请输入 SMB 地址，账号和密码请在各自输入框填写")
    }
    let segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
      .map { String($0).removingPercentEncoding ?? "" }
    guard !segments.isEmpty,
      segments.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
          && $0.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
      })
    else { throw MTVError.message("地址需要包含共享名称，例如 smb://nas/Movies") }
    parts.path = "/" + segments[0]
    parts.scheme = "smb"
    guard let url = parts.url else { throw MTVError.message("无法读取 SMB 地址") }
    shareURL = url
    subdirectory = Array(segments.dropFirst())
  }
  public func directory(in mount: URL) throws -> URL {
    let root = mount.resolvingSymlinksInPath().standardizedFileURL
    let directory = subdirectory.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
      .resolvingSymlinksInPath().standardizedFileURL
    guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
      throw MTVError.message("共享内的目录指向了共享范围之外")
    }
    return directory
  }
}

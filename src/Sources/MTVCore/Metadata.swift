import Foundation

public enum MetadataProvider: String, Codable, CaseIterable { case tmdb, tvmaze }
public enum MetadataKind: String, Codable { case movie, series }
public struct MetadataCandidate: Codable, Hashable, Identifiable {
  public let provider: MetadataProvider
  public let externalID: Int
  public let kind: MetadataKind
  public let title: String
  public let year: Int?
  public let overview: String
  public let poster: String?
  public var originalTitle: String? = nil
  public var officialAliases: [String]? = nil
  public var id: String { provider.rawValue + ":" + kind.rawValue + ":\(externalID)" }
  public var attribution: URL {
    URL(
      string: provider == .tvmaze
        ? "https://www.tvmaze.com/shows/\(externalID)"
        : "https://www.themoviedb.org/\(kind == .movie ? "movie" : "tv")/\(externalID)")!
  }
  public init(
    provider: MetadataProvider, externalID: Int, kind: MetadataKind, title: String,
    year: Int? = nil, overview: String = "", poster: String? = nil
  ) {
    self.provider = provider
    self.externalID = externalID
    self.kind = kind
    self.title = title
    self.year = year
    self.overview = overview
    self.poster = poster
  }
  public func validate() throws {
    guard externalID > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.count <= 512, overview.count <= 30_000,
      year.map({ (1800...2199).contains($0) }) ?? true,
      provider != .tvmaze || kind == .series
    else { throw MTVError.message("元数据内容无效") }
    if let officialAliases {
      guard officialAliases.count <= 100, officialAliases.allSatisfy({ !$0.isEmpty && $0.count <= 512 }) else { throw MTVError.message("别名资料超过限制") }
    }
    if let poster {
      let domains = provider == .tvmaze ? ["static.tvmaze.com"] : ["image.tmdb.org"]
      guard let url = URL(string: poster), NetworkPolicy.permits(url, domains: domains),
        url.fragment == nil, url.query == nil
      else { throw MTVError.message("元数据图片来源未授权") }
    }
  }
}

public protocol MetadataSearching {
  func search(query: String, kind: MetadataKind, provider: MetadataProvider, token: String?)
    async throws -> [MetadataCandidate]
}

private final class MetadataRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

public final class MetadataClient: MetadataSearching, @unchecked Sendable {
  private let session: URLSession
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 15
    session = URLSession(
      configuration: configuration, delegate: MetadataRedirects(), delegateQueue: nil)
  }
  public func localizedSeries(tvmazeID: Int, token: String) async throws -> MetadataCandidate? {
    guard tvmazeID > 0, !token.isEmpty, token.utf8.count <= 4096,
      token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
    struct Show: Decodable {
      struct Externals: Decodable { let imdb: String?; let thetvdb: Int? }
      let externals: Externals
    }
    let (showData, showResponse) = try await session.data(from: URL(string: "https://api.tvmaze.com/shows/\(tvmazeID)")!)
    guard (showResponse as? HTTPURLResponse)?.statusCode == 200, showData.count <= 2_000_000 else { return nil }
    let identifiers = try JSONDecoder().decode(Show.self, from: showData).externals
    var keys: [(String, String)] = []
    if let imdb = identifiers.imdb, imdb.range(of: #"^tt[0-9]+$"#, options: .regularExpression) != nil {
      keys.append((imdb, "imdb_id"))
    }
    if let tvdb = identifiers.thetvdb, tvdb > 0 { keys.append((String(tvdb), "tvdb_id")) }
    struct Find: Decodable {
      struct Result: Decodable { let id: Int; let name: String; let overview: String }
      let tv_results: [Result]
    }
    for (id, source) in keys {
      let url = URL(string: "https://api.themoviedb.org/3/find/\(id)?external_source=\(source)&language=zh-CN")!
      var request = URLRequest(url: url)
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { return nil }
      let results = try JSONDecoder().decode(Find.self, from: data).tv_results
      if results.count == 1, let match = results.first, MetadataStore.containsChinese(match.name) {
        let result = MetadataCandidate(provider: .tmdb, externalID: match.id, kind: .series,
          title: match.name, overview: match.overview)
        try result.validate()
        return result
      }
    }
    return nil
  }
  public func search(query: String, kind: MetadataKind, provider: MetadataProvider, token: String?)
    async throws -> [MetadataCandidate]
  {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 100 else { throw MTVError.message("请输入 1–100 字的片名") }
    var components: URLComponents
    if provider == .tvmaze {
      guard kind == .series else { throw MTVError.message("TVmaze 只提供剧集元数据，请明确选择电影数据源") }
      components = URLComponents(string: "https://api.tvmaze.com/search/shows")!
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    } else {
      guard let token, !token.isEmpty, token.utf8.count <= 4096,
        token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
      else {
        throw MTVError.message("需要先配置你自己的 TMDB API Read Access Token")
      }
      components = URLComponents(
        string: "https://api.themoviedb.org/3/search/\(kind == .movie ? "movie" : "tv")")!
      components.queryItems = [
        URLQueryItem(name: "query", value: query), URLQueryItem(name: "language", value: "zh-CN"),
        URLQueryItem(name: "include_adult", value: "false"),
      ]
    }
    var request = URLRequest(url: components.url!)
    request.setValue("MTV-Mac/0.1", forHTTPHeaderField: "User-Agent")
    if provider == .tmdb {
      request.setValue("Bearer " + token!, forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw MTVError.message("无法读取元数据响应") }
    guard response.statusCode == 200 else {
      if response.statusCode == 429 { throw MTVError.rateLimited }
      throw MTVError.message(L("元数据服务返回 HTTP \(response.statusCode)"))
    }
    guard data.count <= 2_000_000 else { throw MTVError.message("元数据响应超过大小限制") }
    var candidates = try Self.decode(data, kind: kind, provider: provider)
    if provider == .tvmaze, candidates.count <= 5 {
      for index in candidates.indices.prefix(5) {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(500))
        let url = URL(string: "https://api.tvmaze.com/shows/\(candidates[index].externalID)/akas")!
        do {
          let (aliases, reply) = try await session.data(from: url)
          guard let reply = reply as? HTTPURLResponse, reply.statusCode == 200, aliases.count <= 1_000_000 else { continue }
          candidates[index].officialAliases = try Self.decodeTVAliases(aliases)
          try candidates[index].validate()
        } catch { try Task.checkCancellation() /* Optional aliases never erase a valid primary search result. */ }
      }
    }
    return candidates
  }
  public static func decodeTVAliases(_ data: Data) throws -> [String] {
    guard data.count <= 1_000_000 else { throw MTVError.message("别名资料超过大小限制") }
    struct Alias: Decodable { let name: String }
    let aliases = try JSONDecoder().decode([Alias].self, from: data)
    guard aliases.count <= 100, aliases.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 512 }) else { throw MTVError.message("别名资料超过限制") }
    return Array(Set(aliases.map(\.name))).sorted()
  }
  public static func decode(_ data: Data, kind: MetadataKind, provider: MetadataProvider) throws
    -> [MetadataCandidate]
  {
    struct Image: Decodable {
      let medium: String?
      let original: String?
    }
    struct Show: Decodable {
      let id: Int
      let name: String
      let premiered: String?
      let summary: String?
      let image: Image?
    }
    struct TVResult: Decodable { let show: Show }
    struct TMResult: Decodable {
      let id: Int
      let title: String?
      let name: String?
      let overview: String?
      let poster_path: String?
      let release_date: String?
      let first_air_date: String?
      let original_title: String?
      let original_name: String?
    }
    struct TMPage: Decodable { let results: [TMResult] }
    func year(_ text: String?) -> Int? { text.flatMap { Int($0.prefix(4)) } }
    let candidates: [MetadataCandidate]
    if provider == .tvmaze {
      guard kind == .series else { throw MTVError.message("TVmaze 不支持电影匹配") }
      candidates = try JSONDecoder().decode([TVResult].self, from: data).prefix(20).map {
        MetadataCandidate(
          provider: .tvmaze, externalID: $0.show.id, kind: .series, title: $0.show.name,
          year: year($0.show.premiered), overview: plainText($0.show.summary ?? ""),
          poster: $0.show.image?.medium ?? $0.show.image?.original)
      }
    } else {
      candidates = try JSONDecoder().decode(TMPage.self, from: data).results.prefix(20).map {
        let poster = $0.poster_path.flatMap {
          $0.hasPrefix("/") && !$0.contains("..") ? "https://image.tmdb.org/t/p/w500" + $0 : nil
        }
        var candidate = MetadataCandidate(
          provider: .tmdb, externalID: $0.id, kind: kind,
          title: (kind == .movie ? $0.title : $0.name) ?? "",
          year: year(kind == .movie ? $0.release_date : $0.first_air_date),
          overview: $0.overview ?? "", poster: poster)
        candidate.originalTitle = kind == .movie ? $0.original_title : $0.original_name
        return candidate
      }
    }
    for candidate in candidates { try candidate.validate() }
    return candidates
  }
  private static func plainText(_ text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
  }
}

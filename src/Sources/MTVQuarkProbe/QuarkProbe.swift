import Foundation
import MTVCore

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@main enum QuarkProbe {
  static let explicitlyApprovedMediaHost = "video-play-c-sz.drive.quark.cn"
  static func originTransfer(_ url: URL, userAgent: String, direct: Bool, approvedCredential: PluginSession? = nil,
    offset:Int64=0,count:Int=8*1024*1024) async -> [String:Any] {
    let route = direct ? "request-direct":"system-proxy"
    guard let host=url.host, host.hasPrefix("dl-pc-"), FirstPartyMediaScope.isQuarkPlaybackHost(host),
      url.scheme=="https", url.user==nil, url.password==nil, url.port==nil || url.port==443 else {
      return ["route":route,"error":"original-host-not-approved"]
    }
    guard let range=try? HTTPByteRange(offset:offset,count:count,maximumCount:HTTPByteRange.maximumStreamingCount) else {
      return ["route":route,"error":"invalid-diagnostic-range"]
    }
    var request=URLRequest(url:url)
    request.setValue(range.header,forHTTPHeaderField:"Range")
    request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
    request.setValue(userAgent,forHTTPHeaderField:"User-Agent")
    request.setValue("https://pan.quark.cn/",forHTTPHeaderField:"Referer")
    if let approvedCredential {
      do {
        let policy=try RemotePlaybackRequest(url:url,domains:["drive.quark.cn"],headers:["User-Agent":userAgent],referer:"https://pan.quark.cn/")
          .authorizingMediaSession(approvedCredential,approvedHost:host,quarkPlaybackService:true)
        let native=try policy.nativeRequest(for:url)
        request.setValue(native.value(forHTTPHeaderField:"Cookie"),forHTTPHeaderField:"Cookie")
      } catch {
        return ["route":route,"error":"native-session-scope-rejected"]
      }
    }
    var result=await OriginTransferRead(request:request,range:range,direct:direct).run()
    result["route"]=route; result["cookieForwarded"]=approvedCredential != nil
    result["globalProxyConfigurationChanged"]=false
    return result
  }
  static func mediaCheck(_ url: URL, headers: Bool, approvedCredential: PluginSession? = nil, userAgent: String? = nil) async -> [String: Any] {
    guard NetworkPolicy.permitsPlayback(url, domains: ["quark.cn", "quark.com.cn", "uc.cn"]) else {
      return ["headers": headers, "error": "media-domain-not-approved"]
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    if let approvedCredential {
      guard headers, approvedCredential.pluginID == "mtv.quark", FirstPartyMediaScope.isQuarkPlaybackHost(url.host?.lowercased() ?? ""),
        url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
        return ["error": "explicit-media-session-scope-rejected", "cookieForwarded": false]
      }
      request.setValue(approvedCredential.cookie, forHTTPHeaderField: "Cookie")
    }
    if headers {
      request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
      request.setValue(userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      var prefix = Data()
      for try await byte in bytes { prefix.append(byte); if prefix.count == 1024 { break } }
      return ["headers": headers, "cookieForwarded": approvedCredential != nil, "http": (response as? HTTPURLResponse)?.statusCode ?? 0,
        "mime": response.mimeType ?? "unknown", "prefixBytes": prefix.count,
        "isHLS": prefix.starts(with: Data("#EXTM3U".utf8)),
        "isMP4": prefix.count >= 8 && prefix.subdata(in: 4..<8) == Data("ftyp".utf8)]
    } catch { return ["headers": headers, "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code] }
  }
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      let membership = args == ["membership"]
      let useApprovedMediaSession = args.count == 3 && args[2] == "--approved-quark-media-session"
      guard membership || ((args.count == 2 || useApprovedMediaSession) && ["web-transcode", "projection", "original", "origin-transfer", "origin-layout"].contains(args[0]) &&
        args[1].range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil) else {
        throw MTVError.message("Usage: MTVQuarkProbe membership | origin-transfer FILE_ID | web-transcode|projection|original FILE_ID [--approved-quark-media-session]")
      }
      guard let data = try LocalCredentialStore(service: "local.mtv.preview.plugin-session").load(account: "mtv.quark") else {
        throw MTVError.message("No MTV-owned Quark session is saved")
      }
      let credential = try JSONDecoder().decode(PluginSession.self, from: data)
      let originalMode = ["original","origin-transfer","origin-layout"].contains(args[0])
      let path = membership ? "/member" : originalMode ? "/file/download" : args[0] == "projection" ? "/file/v2/play/project" : "/file/v2/play"
      let endpoint = URL(string: "https://drive.quark.cn/1/clouddrive" + path + "?pr=ucpro&fr=pc" +
        (membership ? "&fetch_subscribe=false&_ch=home&fetch_identity=false" : ""))!
      guard credential.pluginID == "mtv.quark", let cookie = credential.cookieHeader(for: endpoint),
        credential.expiresAt.map({ $0 > Date().timeIntervalSince1970 }) ?? true else { throw MTVError.message("MTV session is expired or outside the approved service domain") }
      let config = URLSessionConfiguration.ephemeral
      config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
      config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
      let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: endpoint)
      let userAgent = originalMode ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch" : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
      request.httpMethod = membership ? "GET" : "POST"
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
      request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
      if !membership {
        let body: [String: Any] = originalMode ? ["fids": [args[1]]] :
          ["fid": args[1], "resolutions": "low,normal,high,super,2k,4k", "supports": args[0] == "projection" ? "fmp4_av,m3u8,dolby_vision" : "fmp4"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
      }
      let started = ProcessInfo.processInfo.systemUptime
      let (responseData, response) = try await session.data(for: request)
      guard responseData.count <= 2_000_000, let http = response as? HTTPURLResponse else { throw MTVError.message("Invalid or oversized service response") }
      let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
      var result: [String: Any] = ["schema":1, "mode":args[0], "http":http.statusCode,
        "seconds": ProcessInfo.processInfo.systemUptime - started, "ownSessionRead":true,
        "credentialsPrinted":false, "mediaURLsPrinted":false, "mediaPlaybackVerified":false]
      if let code = object?["code"] as? Int { result["providerCode"] = code }
      if let status = object?["status"] as? Int { result["providerStatus"] = status }
      if let message = object?["message"] as? String { result["providerMessage"] = LocalControlJSON.safeText(String(message.prefix(256))) }
      let dataObject = object?["data"] as? [String: Any]
      if membership {
        if let type = dataObject?["member_type"] as? String,
          type.range(of: #"^[A-Za-z0-9_-]{1,32}$"#,options:.regularExpression) != nil { result["memberType"] = type }
        let status = dataObject?["member_status"] as? [String:Any] ?? [:]
        result["membershipCodes"] = ["VIP","Z_VIP","MINI_VIP","SUPER_VIP"].reduce(into:[String:String]()) { fields, key in
          guard let value = status[key] as? String,
            value.range(of: #"^[A-Za-z0-9_-]{1,32}$"#,options:.regularExpression) != nil else { return }
          fields[key] = value
        }
        if let metadata = object?["metadata"] as? [String:Any], let count = metadata["range_size"] as? Int { result["preferredRangeBytes"] = count }
      }
      let streams = dataObject?["video_list"] as? [[String: Any]] ?? []
      result["streams"] = streams.map { stream -> [String: Any] in
        let video = stream["video_info"] as? [String: Any] ?? [:]
        return ["resolution":String((stream["resolution"] as? String ?? "").prefix(30)),
          "accessible":stream["accessable"] as? Bool ?? false, "urlReturned": !(video["url"] as? String ?? "").isEmpty]
      }
      let originals = object?["data"] as? [[String: Any]] ?? []
      result["originalCount"] = originals.count
      if let size=originals.first?["size"] as? Int { result["originalSizeBytes"]=size }
      if let duration=originals.first?["duration"] as? Double { result["providerDurationRaw"]=duration }
      result["originalURLReturned"] = originals.contains { !($0["download_url"] as? String ?? "").isEmpty }
      if let address = originals.first?["download_url"] as? String, let original = URL(string: address) {
        result["originalHost"] = original.host ?? ""
        result["originalMediaChecks"] = [await mediaCheck(original, headers: true, approvedCredential: useApprovedMediaSession ? credential : nil, userAgent: userAgent)]
        if args[0]=="origin-transfer" {
          var transfers:[[String:Any]]=[]
          for direct in [false,true,true,false] { transfers.append(await originTransfer(original,userAgent:userAgent,direct:direct,
            approvedCredential:useApprovedMediaSession ? credential:nil)) }
          result["originTransferComparison"]=transfers
        }
        if args[0]=="origin-layout" {
          let prefix=await originTransfer(original,userAgent:userAgent,direct:false,
            approvedCredential:useApprovedMediaSession ? credential:nil,count:4096)
          result["prefixLayout"]=prefix
          let layout=prefix["layout"] as? [String:Any] ?? [:]
          let targets=layout["seekTargets"] as? [[String:Any]] ?? []
          var headers:[[String:Any]]=[]
          for target in targets.prefix(8) {
            guard let offset=(target["offset"] as? NSNumber)?.int64Value, offset>=0 else { continue }
            headers.append(await originTransfer(original,userAgent:userAgent,direct:false,
              approvedCredential:useApprovedMediaSession ? credential:nil,offset:offset,count:512))
          }
          result["indexedElementHeaders"]=headers
        }
      }
      let available = streams.filter { $0["accessable"] as? Bool != false }.compactMap { $0["video_info"] as? [String: Any] }
      let selected = available.filter { ($0["height"] as? Int ?? 0) <= 1080 }.sorted { ($0["height"] as? Int ?? 0) > ($1["height"] as? Int ?? 0) }.first
      if let address = selected?["url"] as? String, let url = URL(string: address) {
        result["selectedVideoHeight"] = selected?["height"] as? Int ?? 0
        result["mediaHost"] = url.host ?? ""
        result["mediaPathExtension"] = url.pathExtension
        result["mediaQueryNames"] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        if useApprovedMediaSession {
          // Explicit operator approval only. This diagnostic never changes
          // production sessionDomains or persists a broader credential scope.
          result["mediaChecks"] = [await mediaCheck(url, headers: true, approvedCredential: credential)]
        } else { result["mediaChecks"] = [await mediaCheck(url, headers: false), await mediaCheck(url, headers: true)] }
      }
      FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]) + Data([10]))
      exit(http.statusCode == 200 && object?["code"] as? Int == 0 ? 0 : 2)
    } catch {
      FileHandle.standardError.write(LocalControlJSON.encode(["schema":1,"ok":false,"error":LocalControlJSON.safeText(error.localizedDescription)]) + Data([10]))
      exit(1)
    }
  }
}

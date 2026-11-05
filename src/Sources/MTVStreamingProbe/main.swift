import AppKit
import Foundation
import WebKit

/// Capability observation only. Uses an empty ephemeral website store, requests
/// no content license, and never accesses browser profiles or MTV credentials.
@MainActor final class StreamingProbe: NSObject, WKNavigationDelegate {
  static var retained: StreamingProbe?
  private var window: NSWindow!
  private var web: WKWebView!
  private var finished = false
  private var evaluating = false
  private var httpStatus: Int?
  private let service: String
  private let domains: Set<String>
  init(service: String) {
    self.service = service
    domains = service == "netflix" ? ["www.netflix.com", "netflix.com"] : ["tv.apple.com"]
  }
  func start() {
    NSApp.setActivationPolicy(.accessory)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.mediaTypesRequiringUserActionForPlayback = []
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
    web.navigationDelegate = self
    window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "MTV Streaming Capability Probe"
    window.contentView = web
    window.orderBack(nil)
    let address = service == "netflix" ? "https://www.netflix.com/" : "https://tv.apple.com/"
    web.load(URLRequest(url: URL(string: address)!))
    Task { try? await Task.sleep(for: .seconds(35)); finish(["phase": "timeout"], exitCode: 2) }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil,
      let host = url.host?.lowercased(), domains.contains(host) else {
      decisionHandler(.cancel)
      if navigationAction.targetFrame?.isMainFrame != false { finish(["phase": "unexpected-navigation-blocked"], exitCode: 2) }
      return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if navigationResponse.isForMainFrame { httpStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !evaluating, !finished else { return }
    evaluating = true
    Task {
      let script = #"""
      const result = {
        secureContext: window.isSecureContext === true,
        mediaKeysAPI: typeof navigator.requestMediaKeySystemAccess === 'function',
        webKitMediaKeysAPI: typeof window.WebKitMediaKeys !== 'undefined',
        hlsSupported: document.createElement('video').canPlayType('application/vnd.apple.mpegurl') !== '',
        accountRead: false, contentLicenseRequested: false
      };
      const configurations = [{initDataTypes:['cenc'],
        videoCapabilities:[{contentType:'video/mp4; codecs="avc1.640028"'}]}];
      for (const system of ['com.apple.fps','com.widevine.alpha']) {
        const key = system === 'com.apple.fps' ? 'fairPlayKeySystem' : 'widevineKeySystem';
        if (!result.mediaKeysAPI) { result[key] = 'api-unavailable'; continue; }
        try {
          const access = await Promise.race([
            navigator.requestMediaKeySystemAccess(system, configurations),
            new Promise((_, reject) => setTimeout(() => reject(new Error('probe-timeout')), 5000))
          ]);
          result[key] = access && access.keySystem === system ? 'accepted' : 'unexpected-result';
        } catch (error) {
          result[key] = error && error.name === 'NotSupportedError' ? 'not-supported-for-tested-configuration' :
            error && error.message === 'probe-timeout' ? 'timeout' : 'request-rejected';
        }
      }
      return result;
      """#
      do {
        let value = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        guard let capabilities = value as? [String: Any] else { finish(["phase": "invalid-capability-response"], exitCode: 2); return }
        finish(["phase": "observed", "capabilities": capabilities], exitCode: 0)
      } catch { finish(["phase": "capability-observation-failed", "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code], exitCode: 2) }
    }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure(error) }
  private func failure(_ error: Error) {
    finish(["phase": "navigation-failed", "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code], exitCode: 2)
  }
  private func finish(_ observation: [String: Any], exitCode: Int32) {
    guard !finished else { return }; finished = true
    var result = observation
    result["schema"] = 1; result["service"] = service
    result["ephemeralProfile"] = true; result["credentialsRead"] = false
    result["actualAccountPlaybackVerified"] = false; result["imagesUsed"] = false
    result["scope"] = "WebKit key-system configuration observation; not service playback or DRM entitlement approval"
    if let httpStatus { result["mainHTTPStatus"] = httpStatus }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
      FileHandle.standardOutput.write(data + Data([10]))
    }
    web.stopLoading(); window.close()
    exit(exitCode)
  }
}

guard CommandLine.arguments.count == 2, ["netflix", "apple-tv"].contains(CommandLine.arguments[1]) else {
  FileHandle.standardError.write(Data("Usage: MTVStreamingProbe netflix|apple-tv\n".utf8)); exit(1)
}
let application = NSApplication.shared
Task { @MainActor in
  let probe = StreamingProbe(service: CommandLine.arguments[1])
  StreamingProbe.retained = probe
  probe.start()
}
application.run()

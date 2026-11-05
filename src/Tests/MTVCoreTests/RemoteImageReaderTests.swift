import Foundation
import Testing
@testable import MTVCore

private final class ImageProtocolFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url else { return }
    if url.path == "/cancel" { return }
    var headers = ["Content-Type":url.path == "/html" ? "text/html":"image/jpeg"]
    if url.path == "/declared-large" { headers["Content-Length"] = "10000" }
    let response = HTTPURLResponse(url:url,statusCode:url.path == "/forbidden" ? 403:200,httpVersion:"HTTP/1.1",headerFields:headers)!
    client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:Data(repeating:1,count:url.path == "/stream-large" ? 200:4))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

struct RemoteImageReaderTests {
  private func reader(_ path: String) throws -> RemoteImageReader {
    let request = try RemotePlaybackRequest(url:URL(string:"https://images.quark.test"+path)!,domains:["quark.test"],headers:[:],referer:nil)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ImageProtocolFixture.self]
    return RemoteImageReader(request:request,maximum:32,configuration:configuration)
  }
  @Test func acceptsWholeImagesWithoutRequiringHTTPRange() async throws {
    #expect(try await reader("/valid").read() == Data(repeating:1,count:4))
  }
  @Test func rejectsDeclaredAndStreamingOversizeAndHTML() async throws {
    for path in ["/declared-large","/stream-large","/html"] {
      await #expect(throws: Error.self) { try await reader(path).read() }
    }
  }
  @Test func cancellationCompletesEvenWhenServerNeverResponds() async throws {
    let reader = try reader("/cancel")
    let task = Task { try await reader.read() }
    try await Task.sleep(for:.milliseconds(20)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
  @Test func responseDiagnosticsSeparateProviderRefusalFromTypeAndSizeFailures() async throws {
    for (path, status, large, type) in [("/forbidden",403,false,false),("/declared-large",200,true,false),("/html",200,false,true)] {
      do { _ = try await reader(path).read(); Issue.record("Invalid response accepted") }
      catch let failure as RemoteImageResponseError {
        #expect(failure.status == status)
        #expect(failure.oversized == large)
        #expect(failure.unsupportedType == type)
        #expect(!failure.localizedDescription.contains("quark.test"))
      }
    }
  }
  @Test func onlyDeniedOrExpiredRenditionsPermitOriginalPreview() {
    for status in [200,301,401,403,404,410,429,500,503] {
      let failure = RemoteImageResponseError(status:status,oversized:false,unsupportedType:false)
      #expect(failure.permitsOriginalPreview == [401,403,404,410].contains(status))
    }
  }
}

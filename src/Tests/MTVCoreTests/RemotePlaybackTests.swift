import Foundation
import Testing
@testable import MTVCore

struct RemotePlaybackTests {
  @Test func optionalRepeatedHeadersPreserveKnowledgeButExplicitChangesFail() {
    let old = HTTPResourceVersion(etag: "\"version-1\"", lastModified: "Wed, 28 Oct 2026 10:00:00 GMT")
    #expect(!old.conflicts(with: HTTPResourceVersion()))
    #expect(old.merging(HTTPResourceVersion()) == old)
    #expect(old.conflicts(with: HTTPResourceVersion(etag: "\"version-2\"")))
    #expect(!old.conflicts(with: HTTPResourceVersion(lastModified: "Thu, 29 Oct 2026 10:00:00 GMT")))
    #expect(old.ifRangeValue == "\"version-1\"")
    #expect(HTTPResourceVersion(etag: "W/\"weak\"").ifRangeValue == nil)
    #expect(HTTPResourceVersion(lastModified: "Wed, 28 Oct 2026 10:00:00 GMT").ifRangeValue == nil)
    #expect(HTTPResourceVersion(etag: "\"bad\r\nvalue\"").ifRangeValue == nil)
  }
  @Test func onlyProvenStrongTimestampsCanRejectChangedRanges() {
    let cached = HTTPResourceVersion(lastModified: "Wed, 28 Oct 2026 22:52:18 GMT", responseDate: "Thu, 29 Oct 2026 03:46:46 GMT")
    let clock = HTTPResourceVersion(lastModified: "Thu, 29 Oct 2026 03:46:46 GMT", responseDate: "Thu, 29 Oct 2026 03:46:46 GMT")
    #expect(cached.lastModifiedIsStrong && !clock.lastModifiedIsStrong && !cached.conflicts(with: clock))
    let changed = HTTPResourceVersion(lastModified: "Thu, 29 Oct 2026 03:40:00 GMT", responseDate: "Thu, 29 Oct 2026 03:46:46 GMT")
    #expect(cached.conflicts(with: changed))
    let sameBytes = HTTPResourceVersion(etag: "\"same\"", lastModified: cached.lastModified, responseDate: cached.responseDate)
    #expect(!sameBytes.conflicts(with: HTTPResourceVersion(etag: "\"same\"", lastModified: changed.lastModified, responseDate: changed.responseDate)))
    #expect(!HTTPResourceVersion(etag: "W/\"a\"").conflicts(with: HTTPResourceVersion(etag: "W/\"b\"")))
    #expect(!sameBytes.conflicts(with: HTTPResourceVersion(), confirmedIfRange: "\"same\""))
    #expect(sameBytes.conflicts(with: HTTPResourceVersion(etag: "W/\"same\""), confirmedIfRange: "\"same\""))
    #expect(sameBytes.conflicts(with: HTTPResourceVersion(etag: "\"changed\""), confirmedIfRange: "\"same\""))
    #expect(HTTPResourceVersion(etag: "\"newer\"").conflicts(with: HTTPResourceVersion(), confirmedIfRange: "\"same\""))
  }
  @Test func playbackHeadersCannotCarryCredentialsOrInjection() throws {
    let url = URL(string: "https://media.example.org/movie.mp4")!
    for headers in [["Cookie": "session=private"], ["Authorization": "Bearer private"],
      ["Host": "other.example"], ["Range": "bytes=0-2"], ["User-Agent": "bad\r\nX-Test: true"],
      ["User-Agent": "a", "user-agent": "b"], ["Referer": "https://site.example/?token=private"]] {
      #expect(throws: (any Error).self) { try RemotePlaybackRequest(url: url, domains: ["example.org"],
        headers: headers, referer: "https://site.example/") }
    }
    let request = try RemotePlaybackRequest(url: url, domains: ["example.org"],
      headers: ["Referer": "https://site.example/", "User-Agent": "MTV test"], referer: "https://site.example/")
    #expect(request.headers["referer"] == "https://site.example/")
    #expect(request.permits(URL(string: "https://cdn.example.org/part.mp4")!))
    for target in ["https://example.org.evil.test/movie", "http://media.example.org/movie", "https://media.example.org:8443/movie",
      "https://user:pass@media.example.org/movie", "https://media.example.org/movie#fragment", "http://127.0.0.1:8080/mtv-fixture/movie.mp4"] {
      #expect(!request.permits(URL(string: target)!))
    }
  }
  @Test func fixtureExceptionCannotBeConstructedInNormalProcess() {
    #expect(throws: (any Error).self) { try RemotePlaybackRequest.testingLoopback(
      url: URL(string: "http://127.0.0.1:8123/mtv-fixture/movie.mp4")!, headers: [:], referer: nil) }
  }
  @Test func rangesValidateEOFAndRejectWrongResponses() throws {
    let range = try HTTPByteRange(offset: 4, count: 8)
    #expect(range.header == "bytes=4-11")
    let eof = try HTTPRangeResponse(status: 206, contentRange: "bytes 4-9/10", contentLength: "6", encoding: nil, requested: range)
    #expect(eof.count == 6 && eof.totalLength == 10)
    for bad in ["bytes 0-7/10", "bytes 4-8/10", "bytes 4-11/10", "bytes 4-9/*", "bytes +4-9/10", "bytes 4-9/0"] {
      #expect(throws: (any Error).self) { try HTTPRangeResponse(status: 206, contentRange: bad,
        contentLength: nil, encoding: nil, requested: range) }
    }
    #expect(throws: (any Error).self) { try HTTPRangeResponse(status: 200, contentRange: "bytes 4-9/10", contentLength: "6", encoding: nil, requested: range) }
    #expect(throws: (any Error).self) { try HTTPRangeResponse(status: 206, contentRange: "bytes 4-9/10", contentLength: "7", encoding: nil, requested: range) }
    #expect(throws: (any Error).self) { try HTTPRangeResponse(status: 206, contentRange: "bytes 4-9/10", contentLength: "6", encoding: "gzip", requested: range) }
  }
  @Test func extremeOffsetsCannotOverflowOrAllocateUnboundedChunks() throws {
    #expect(try HTTPByteRange(offset: Int64.max, count: 1).header == "bytes=9223372036854775807-9223372036854775807")
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: Int64.max, count: 2) }
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: -1, count: 2) }
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: 0, count: 1_048_577) }
    #expect(try HTTPByteRange(offset: 0, count: 4_194_304, maximumCount: 4_194_304).upperBound == 4_194_303)
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: 0, count: 4_194_305, maximumCount: 4_194_304) }
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: 0, count: 1, maximumCount: Int.max) }
    #expect(try HTTPByteRange(offset: 0, count: 10_485_760, maximumCount: HTTPByteRange.maximumStreamingCount).count == 10_485_760)
    #expect(throws: (any Error).self) { try HTTPByteRange(offset: 0, count: 10_485_761, maximumCount: HTTPByteRange.maximumStreamingCount) }
  }
}

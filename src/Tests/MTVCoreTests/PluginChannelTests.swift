import Foundation
import Testing
@testable import MTVCore

struct PluginChannelTests {
  private final class BlockedTransport: URLProtocol, @unchecked Sendable {
    static var onStart: (@Sendable () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "hold.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() {}
  }
  private final class CancellationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var began: TimeInterval?
    func mark() { lock.lock(); began = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return began != nil }
    var elapsed: TimeInterval {
      lock.lock(); defer { lock.unlock() }
      return began.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
    }
  }
  @Test func framesRoundTripAndRejectTruncationOversizeAndBrokenPipe() throws {
    let pipe = Pipe()
    try PluginChannel.write(["type": "fetch", "id": 1, "url": "https://example.com/"], to: pipe.fileHandleForWriting, maximum: 1024)
    try pipe.fileHandleForWriting.close()
    let value = try PluginChannel.read(from: pipe.fileHandleForReading, maximum: 1024)
    #expect(value?["id"] as? Int == 1)
    #expect(try PluginChannel.read(from: pipe.fileHandleForReading, maximum: 1024) == nil)
    let truncated = Pipe()
    try truncated.fileHandleForWriting.write(contentsOf: Data([0, 0, 0, 10, 123]))
    try truncated.fileHandleForWriting.close()
    #expect(throws: (any Error).self) { try PluginChannel.read(from: truncated.fileHandleForReading, maximum: 1024) }
    let oversized = Pipe()
    try oversized.fileHandleForWriting.write(contentsOf: Data([255, 255, 255, 255]))
    #expect(throws: (any Error).self) { try PluginChannel.read(from: oversized.fileHandleForReading, maximum: 1024) }
    let broken = Pipe(); try broken.fileHandleForReading.close()
    #expect(throws: (any Error).self) { try PluginChannel.write(["value": "safe"], to: broken.fileHandleForWriting, maximum: 1024) }
  }
  @Test func nativeBrokerRejectsUnapprovedRequestsAndCancellation() throws {
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"dev.test.broker","name":"Test","version":"1","apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse"]}"#.utf8))
    let broker = try PluginNetworkBroker(manifest: manifest, action: "browse", credential: nil)
    #expect(!broker.sessionAvailable)
    let denied = broker.request("https://not-approved.invalid/", optionsJSON: "{}")
    #expect(denied.contains("拒绝请求"))
    #expect(broker.request("https://not-approved.invalid/", optionsJSON: #"{"method":"POST","body":{}}"#).contains("未授权"))
    #expect(broker.request("https://not-approved.invalid/", optionsJSON: #"{"captureSession":true}"#).contains("仅登录"))
    broker.cancel()
    #expect(broker.request("https://not-approved.invalid/", optionsJSON: "{}").contains("取消"))
  }
  @Test func cancellingAnObservedPendingNativeRequestWakesItsWaiter() async throws {
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"dev.test.pending","name":"Test","version":"1","apiVersion":1,"entry":"plugin.js","domains":["hold.example.test"],"capabilities":["browse"]}"#.utf8))
    let broker = try PluginNetworkBroker(manifest: manifest, action: "browse", credential: nil)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BlockedTransport.self]
    broker.useConfigurationForTesting(configuration)
    // Cancel from the transport's actual start event. A Swift task resuming on
    // a busy CI executor must not delay cancellation until the request expires.
    // The blocked synchronous caller lives on its own dispatch queue, just as
    // the production async adapter keeps it off Swift's cooperative executor.
    let observation = CancellationObservation()
    BlockedTransport.onStart = { observation.mark(); broker.cancel() }
    defer { BlockedTransport.onStart = nil; broker.cancel() }
    let result: (String, Double) = await withCheckedContinuation { continuation in
      DispatchQueue(label: "MacTV owned pending broker fixture").async {
        let response = broker.request("https://hold.example.test/data", optionsJSON: "{}")
        continuation.resume(returning: (response, observation.elapsed))
      }
    }
    #expect(observation.started)
    #expect(result.0.contains("取消") && result.1 < 1)

  }
}

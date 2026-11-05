import Foundation
import MTVCore

private final class PluginProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  private var cancelAction: (@Sendable () -> Void)?
  func onCancel(_ action: @escaping @Sendable () -> Void) {
    lock.lock(); cancelAction = action; let stopped = cancelled; lock.unlock()
    if stopped { action() }
  }
  func start(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    try process.run()
    self.process = process
  }
  func cancel() {
    lock.lock()
    cancelled = true; let action = cancelAction, process = process
    lock.unlock()
    action?()
    if let process, process.isRunning { process.terminate() }
  }
  func runningPID() -> Int32? {
    lock.lock(); defer { lock.unlock() }
    guard let process, process.isRunning else { return nil }; return process.processIdentifier
  }
}

private final class PluginExecutions: @unchecked Sendable {
  static let shared = PluginExecutions()
  private let lock = NSLock()
  private var boxes: [String: [UUID: PluginProcessBox]] = [:]
  func add(_ box: PluginProcessBox, plugin: String) -> UUID {
    lock.lock(); defer { lock.unlock() }; let id = UUID(); boxes[plugin, default: [:]][id] = box; return id
  }
  func remove(_ id: UUID, plugin: String) {
    lock.lock(); defer { lock.unlock() }; boxes[plugin]?[id] = nil
    if boxes[plugin]?.isEmpty == true { boxes[plugin] = nil }
  }
  func cancel(_ plugin: String) {
    lock.lock(); let values = boxes[plugin].map { Array($0.values) } ?? []; lock.unlock()
    for box in values { box.cancel() }
  }
  func cancelExternal() {
    lock.lock(); let values = boxes.filter { !$0.key.hasPrefix("mtv.") }.flatMap { Array($0.value.values) }; lock.unlock()
    for box in values { box.cancel() }
  }
  func running(_ plugin: String) -> [Int32] {
    lock.lock(); let values = boxes[plugin].map { Array($0.values) } ?? []; lock.unlock()
    return values.compactMap { $0.runningPID() }
  }
}
enum PluginClient {
  enum SessionAccess { case stored, guest }
  struct Execution {
    let data: Data
    let session: PluginSession?
  }
  static var root: URL { Bundle.main.resourceURL!.appendingPathComponent("plugins") }
  static let packages: PluginPackageStore = {
    if CommandLine.arguments.contains("--ui-smoke") {
      if let index = CommandLine.arguments.firstIndex(of: "--plugin-install-scope"), index + 1 < CommandLine.arguments.count,
        let scope = UUID(uuidString: CommandLine.arguments[index + 1]) {
        return PluginPackageStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/TestResults/PluginPackagesStartup-" + scope.uuidString.lowercased()))
      }
      return PluginPackageStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/TestResults/PluginPackages-\(ProcessInfo.processInfo.processIdentifier)"))
    }
    return PluginPackageStore()
  }()
  static func cancel(pluginID: String) { PluginExecutions.shared.cancel(pluginID) }
  static func cancelExternal() { PluginExecutions.shared.cancelExternal() }
  static func runningProcessIDs(pluginID: String) -> [Int32] {
    guard CommandLine.arguments.contains("--ui-smoke") else { return [] }; return PluginExecutions.shared.running(pluginID)
  }
  static func execute(
    _ plugin: PluginRecord, action: String, input: [String: String] = [:],
    sessionAccess: SessionAccess = .stored
  )
    async throws -> Data
  {
    try await executeWithSession(plugin, action: action, input: input, sessionAccess: sessionAccess)
      .data
  }
  static func executeWithSession(
    _ plugin: PluginRecord, action: String, input: [String: String] = [:],
    sessionAccess: SessionAccess = .stored
  )
    async throws -> Execution
  {
    let allowedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let external = !plugin.directory.standardizedFileURL.path.hasPrefix(allowedRoot)
      || !plugin.directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(allowedRoot)
    if external { _ = try await packages.resolve(plugin) }
    guard plugin.manifest.capabilities.contains(action) else {
      throw MTVError.message(L("此插件不支持该操作：\(action)"))
    }
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MTVPluginHost.app/Contents/MacOS/MTVPluginHost")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw MTVError.message("缺少沙箱插件宿主，拒绝使用未隔离的备用进程") }
    try PluginHostIsolation.validate(executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    let processBox = PluginProcessBox()
    let executionID = PluginExecutions.shared.add(processBox, plugin: plugin.id)
    defer { PluginExecutions.shared.remove(executionID, plugin: plugin.id) }
    let runner = Task.detached(priority: .userInitiated) {
      var nativeRequest: [String: Any] = ["action": action, "input": input]
      guard try JSONSerialization.data(withJSONObject: nativeRequest).count <= 64_000 else { throw MTVError.message("插件操作输入超过大小限制") }
      let approved = external ? try await packages.resolve(plugin) : plugin
      nativeRequest["approvedManifest"] = try JSONSerialization.jsonObject(with: PluginPackageStore.approvalBytes(approved.manifest))
      let script = try PluginPackageFiles.read("plugin.js", at: approved.directory, maximum: 1_000_000)
      nativeRequest["scriptBase64"] = script.base64EncodedString()
      let credential: PluginSession?
      if sessionAccess == .stored, plugin.manifest.authentication != nil && action != "login" {
        credential = try PluginSessionStore().load(pluginID: plugin.id)
      } else { credential = nil }
      let broker = try PluginNetworkBroker(manifest: approved.manifest, action: action, credential: credential)
      let nativeCancellation = NativeLibraryCancellation()
      processBox.onCancel { broker.cancel(); nativeCancellation.cancel() }
      nativeRequest["sessionAvailable"] = broker.sessionAvailable
      let request = try JSONSerialization.data(withJSONObject: nativeRequest)
      guard request.count <= 1_600_000 else { throw MTVError.message("插件输入超过大小限制") }
      let process = Process()
      let environment = ["PATH": "/usr/bin:/bin", "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"]
      process.environment = environment
      let output = Pipe()
      let stdin = Pipe()
      process.executableURL = executable
      process.arguments = ["--brokered"]
      process.currentDirectoryURL = URL(fileURLWithPath: "/")
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.standardInput = stdin
      try Task.checkCancellation()
      let exitObservation = try ProcessExitObservation(process)
      try processBox.start(process)
      let deadline = DispatchWorkItem { processBox.cancel() }
      DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
      defer { deadline.cancel(); broker.cancel(); try? stdin.fileHandleForWriting.close(); if process.isRunning { processBox.cancel() } }
      try PluginChannel.write(nativeRequest, to: stdin.fileHandleForWriting, maximum: 1_600_000)
      var result: [String: Any]?
      var expectedRequest = 1
      if approved.manifest.apiVersion==2 {
        let channel=PluginAsyncRPC(reader:output.fileHandleForReading,writer:stdin.fileHandleForWriting)
        result=try await channel.run(handler:{ request in
          switch request.kind {
          case .fetch:
            let response=await broker.requestAsync(request.argument,optionsJSON:request.options)
            guard response.utf8.count<=2_100_000 else { throw MTVError.message("Plugin response exceeds its size limit") }
            return Data(response.utf8)
          case .library:
            guard approved.manifest.nativeLibraries?.contains(request.argument)==true,
              let data=request.options.data(using:.utf8), let values=try JSONSerialization.jsonObject(with:data) as? [String:String] else { throw MTVError.message("Native resource access was not declared") }
            if request.argument=="photos" { return try await PhotoResources.browse(owner:plugin.id,input:values,cancellation:nativeCancellation) }
            if request.argument=="quark-pictures" { return try await CloudPhotos.shared.browse(requester:plugin.id,input:values) }
            return try await NativeLibrary.shared.requestAsync(pluginID:plugin.id,services:approved.manifest.nativeLibraries ?? [],service:request.argument,input:values,cancellation:nativeCancellation)
          }
        },cancel:{ broker.cancel(); nativeCancellation.cancel() },terminate:{ processBox.cancel() })
      } else {
      while let frame = try PluginChannel.read(from: output.fileHandleForReading, maximum: 2_100_000) {
        guard let type = frame["type"] as? String else { throw MTVError.message("插件通信类型缺失") }
        if type == "library" {
          guard expectedRequest <= 64, Set(frame.keys) == ["type", "id", "service", "input"],
            frame["id"] as? Int == expectedRequest, let service = frame["service"] as? String,
            let input = frame["input"] as? String, input.utf8.count <= 16_384,
            let data = input.data(using:.utf8), let values = try JSONSerialization.jsonObject(with:data) as? [String:String] else {
            throw MTVError.message("Invalid native library request")
          }
          let payload: Data
          do {
            guard approved.manifest.nativeLibraries?.contains(service) == true else { throw MTVError.message("Native library service was not declared") }
            if service == "photos" { payload = try await PhotoResources.browse(owner:plugin.id,input:values,cancellation:nativeCancellation) }
            else if service == "quark-pictures" { payload = try await CloudPhotos.shared.browse(requester:plugin.id,input:values) }
            else { payload = try NativeLibrary.shared.request(pluginID:plugin.id,services:approved.manifest.nativeLibraries ?? [],service:service,input:values,cancellation:nativeCancellation) }
          }
          catch { payload = Data(PluginNetworkBroker.json(["error":error.localizedDescription]).utf8) }
          try PluginChannel.write(["type":"reply", "id":expectedRequest, "payload":payload.base64EncodedString()],to:stdin.fileHandleForWriting,maximum:3_000_000)
          expectedRequest += 1
        } else if type == "fetch" {
          guard expectedRequest <= 64, Set(frame.keys) == ["type", "id", "url", "options"],
            frame["id"] as? Int == expectedRequest, let address = frame["url"] as? String,
            let options = frame["options"] as? String else { throw MTVError.message("插件代理请求无效") }
          var response = broker.request(address, optionsJSON: options)
          if response.utf8.count > 2_100_000 { response = PluginNetworkBroker.json(["error": "插件代理响应过大"]) }
          try PluginChannel.write(["type": "reply", "id": expectedRequest, "payload": Data(response.utf8).base64EncodedString()],
            to: stdin.fileHandleForWriting, maximum: 3_000_000)
          expectedRequest += 1
        } else if type == "result", Set(frame.keys) == ["type", "result"], let value = frame["result"] as? [String: Any] {
          result = value; break
        } else if type == "error", let error = frame["error"] as? String { throw MTVError.message(String(error.prefix(4096))) }
        else { throw MTVError.message("插件通信帧未授权") }
      }
      }
      try stdin.fileHandleForWriting.close()
      let exitResult = await exitObservation.wait()
      guard !exitResult.signalled else {
        throw MTVError.message("插件超过执行限制或异常退出")
      }
      guard exitResult.status == 0, let result else {
        throw MTVError.message("插件超时或异常退出")
      }
      let capturedSession = broker.capturedSession(result: result)
      if let original = credential, let refreshed = broker.refreshedSession {
        _ = try PluginSessionStore().replace(original, with: refreshed)
      }
      return Execution(
        data: try JSONSerialization.data(withJSONObject: result), session: capturedSession)
    }
    return try await withTaskCancellationHandler(
      operation: {
        try await runner.value
      },
      onCancel: {
        runner.cancel()
        processBox.cancel()
      })
  }
}

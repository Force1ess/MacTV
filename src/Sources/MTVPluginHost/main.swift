import Darwin
import Foundation
import JavaScriptCore
import MTVCore

// Production mode has no network entitlement and receives no private session.
let brokered = CommandLine.arguments.dropFirst().first == "--brokered"
do {
  // A GUI parent's DispatchSource signal setup must not make this worker immune
  // to its own deadline/cancellation. Reset inherited ignored dispositions.
  signal(SIGTERM, SIG_DFL)
  signal(SIGINT, SIG_DFL)
  signal(SIGXCPU, SIG_DFL)
  // Bound CPU consumption. Parent also enforces a wall-clock deadline.
  var cpu = rlimit(rlim_cur: 8, rlim_max: 10)
  _ = setrlimit(RLIMIT_CPU, &cpu)
  try IsolationProbe.runIfRequested()
  guard CommandLine.arguments.count == 2 else { throw MTVError.message("需要插件目录或已审核输入") }
  if Bundle.main.bundleIdentifier == "local.mtv.plugin-host", !brokered { throw MTVError.message("隔离脚本宿主只接受原生代理通道") }
  let suppliedCode = CommandLine.arguments[1] == "--payload" || brokered
  let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let inputLimit = suppliedCode ? 1_600_000 : 64_000
  let object: [String: Any]
  if brokered {
    guard let frame = try PluginChannel.read(from: .standardInput, maximum: inputLimit) else { throw MTVError.message("缺少插件启动帧") }
    object = frame
  } else {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard inputData.count <= inputLimit, let frame = try JSONSerialization.jsonObject(with: inputData) as? [String: Any] else { throw MTVError.message("插件输入无效") }
    object = frame
  }
  let manifestBytes: Data
  if let approved = object["approvedManifest"] { manifestBytes = try JSONSerialization.data(withJSONObject: approved) }
  else if suppliedCode { throw MTVError.message("沙箱宿主缺少已审核清单") }
  else { manifestBytes = try PluginPackageFiles.read("manifest.json", at: directory, maximum: 16_384) }
  let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestBytes)
  try manifest.validate()
  guard let action = object["action"] as? String,
    manifest.capabilities.contains(action)
  else { throw MTVError.message("插件未声明此操作能力") }
  let credential: PluginSession?
  if brokered, object["credential"] != nil { throw MTVError.message("无网络脚本进程不能接收私有会话") }
  if !brokered, let rawCredential = object["credential"] {
    let data = try JSONSerialization.data(withJSONObject: rawCredential)
    let candidate = try JSONDecoder().decode(PluginSession.self, from: data)
    try candidate.validate(for: manifest)
    credential = candidate
  } else {
    credential = nil
  }
  let network = brokered ? nil : try PluginNetworkBroker(manifest: manifest, action: action, credential: credential)
  let available = brokered ? object["sessionAvailable"] as? Bool == true : credential != nil
  var requestNumber = 0
  guard let context = JSContext() else { throw MTVError.message("JavaScriptCore 初始化失败") }
  var jsError: String?
  context.exceptionHandler = { _, exception in jsError = exception?.toString() ?? "插件异常" }
  let bridge: @convention(block) (String, String) -> String = { address, optionsJSON in
    if let network { return network.request(address, optionsJSON: optionsJSON) }
    do {
      guard address.utf8.count <= 16_384, optionsJSON.utf8.count <= 131_072, requestNumber < 64 else { throw MTVError.message("插件代理请求超过限制") }
      requestNumber += 1
      try PluginChannel.write(["type": "fetch", "id": requestNumber, "url": address, "options": optionsJSON], to: .standardOutput, maximum: 262_144)
      guard let frame = try PluginChannel.read(from: .standardInput, maximum: 3_000_000),
        frame["type"] as? String == "reply", frame["id"] as? Int == requestNumber,
        let encoded = frame["payload"] as? String, let data = Data(base64Encoded: encoded), data.count <= 2_100_000,
        let value = String(data: data, encoding: .utf8) else { throw MTVError.message("插件代理响应无效") }
      return value
    } catch { return PluginNetworkBroker.json(["error": error.localizedDescription]) }
  }
  context.setObject(bridge, forKeyedSubscript: "__fetch" as NSString)
  let libraryBridge: @convention(block) (String, String) -> String = { service, inputJSON in
    do {
      guard brokered, manifest.nativeLibraries?.contains(service) == true,
        inputJSON.utf8.count <= 16_384, requestNumber < 64 else { throw MTVError.message("Native library access was not declared") }
      requestNumber += 1
      try PluginChannel.write(["type":"library", "id":requestNumber, "service":service, "input":inputJSON],to:.standardOutput,maximum:32_768)
      guard let reply = try PluginChannel.read(from:.standardInput,maximum:3_000_000), reply["type"] as? String == "reply",
        reply["id"] as? Int == requestNumber, let encoded = reply["payload"] as? String,
        let data = Data(base64Encoded:encoded), let text = String(data:data,encoding:.utf8) else { throw MTVError.message("Invalid native library reply") }
      return text
    } catch { return PluginNetworkBroker.json(["error":error.localizedDescription]) }
  }
  context.setObject(libraryBridge, forKeyedSubscript:"__library" as NSString)
  let asyncInvocation: (() throws -> String)?
  if manifest.apiVersion==2 {
    guard brokered else { throw MTVError.message("Async API requires the native broker") }
    asyncInvocation=try prepareAsyncPlugin(context:context,available:available,exception:{jsError})
  } else {
  asyncInvocation=nil
  context.evaluateScript(
    """
    const host = Object.freeze({ sessionAvailable: \(available ? "true" : "false"), library(service, input) {
      const r=JSON.parse(__library(service, JSON.stringify(input || {})));
      if(r.error) throw Error(r.error); return r;
    }, fetchJSON(url, options) {
      const r=JSON.parse(__fetch(url, JSON.stringify(options || {})));
      if(r.error) throw Error(r.error);
      if(r.status===412) throw Error('平台拒绝了当前请求（HTTP 412），尚未通过平台验证；不会自动重试或切换接口');
      if(r.status===429) throw Error('请求过于频繁（HTTP 429），请稍后重试');
      if(r.status!==200) throw Error('HTTP '+r.status+(Number.isSafeInteger(r.providerCode)?' · 平台错误码 '+r.providerCode:''));
      return JSON.parse(r.body);
    } });
    """)
  }
  let scriptBytes: Data
  if suppliedCode {
    guard let encoded = object["scriptBase64"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count <= 1_000_000 else { throw MTVError.message("沙箱宿主缺少有效脚本") }
    scriptBytes = bytes
  } else { scriptBytes = try PluginPackageFiles.read("plugin.js", at: directory, maximum: 1_000_000) }
  guard let code = String(data: scriptBytes, encoding: .utf8) else { throw MTVError.message("插件脚本必须是 UTF-8") }
  guard code.utf8.count <= 1_000_000 else { throw MTVError.message("插件代码过大") }
  context.evaluateScript(code)
  if let jsError { throw MTVError.message(jsError) }
  // Do NOT pass the complete native request: it can contain a private session.
  context.setObject(
    ["action": action, "input": object["input"] ?? [:]], forKeyedSubscript: "__request" as NSString)
  let text: String
  if let asyncInvocation { text=try asyncInvocation() }
  else {
    let value=context.evaluateScript("JSON.stringify(plugin.handle(__request.action,__request.input || {}))")
    if let jsError { throw MTVError.message(jsError) }
    guard let returned=value?.toString() else { throw MTVError.message("插件返回值无效") }
    text=returned
  }
  if let jsError { throw MTVError.message(jsError) }
  guard let data=text.data(using:.utf8), data.count<=2_000_000 else { throw MTVError.message("插件返回值无效") }
  let result = try JSONSerialization.jsonObject(with: data)
  if brokered {
    try PluginChannel.write(["type": "result", "result": result], to: .standardOutput, maximum: 2_100_000)
  } else {
    var envelope: [String: Any] = ["result": result]
    if let session = network?.capturedSession(result: result) {
      envelope["credential"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session))
    }
    print(PluginNetworkBroker.json(envelope))
  }
} catch {
  if brokered { try? PluginChannel.write(["type": "error", "error": error.localizedDescription], to: .standardOutput, maximum: 65_536) }
  else { print(PluginNetworkBroker.json(["error": error.localizedDescription])) }
  exit(1)
}

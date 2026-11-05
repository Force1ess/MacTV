import Foundation
import MTVCore
import RimeBridge

struct PinyinState {
  var input = ""
  var preedit = ""
  var candidates: [String] = []
  var commit = ""
  var page = 0
  var lastPage = true
}

/// Initialization/deployment happens off the UI thread. Afterwards the handle is
/// used only by the main actor, just like a native input-method key event path.
private final class RimeHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  init(root: URL, user: URL) throws {
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    var error = [CChar](repeating: 0, count: 2048)
    guard let pointer = mtv_rime_create(root.path, user.path, &error, error.count) else {
      throw MTVError.message(String(cString: error))
    }
    self.pointer = pointer
  }
  deinit { mtv_rime_destroy(pointer) }
  @MainActor func apply(_ operation: Int32, _ argument: Int32 = 0) throws -> PinyinState {
    guard let result = mtv_rime_apply(pointer, operation, argument) else {
      throw MTVError.message("无法读取拼音候选")
    }
    defer { mtv_rime_free_result(result) }
    return PinyinState(
      input: String(cString: mtv_rime_input(result)),
      preedit: String(cString: mtv_rime_preedit(result)),
      candidates: (0..<mtv_rime_count(result)).map {
        String(cString: mtv_rime_candidate(result, $0))
      },
      commit: String(cString: mtv_rime_commit(result)), page: Int(mtv_rime_page(result)),
      lastPage: mtv_rime_last_page(result) != 0)
  }
}

@MainActor final class PinyinEngine: ObservableObject {
  @Published private(set) var state = PinyinState()
  @Published private(set) var ready = false
  @Published private(set) var failure: String?
  private var engine: RimeHandle?
  init() {
    let root = Bundle.main.resourceURL!.appendingPathComponent("RimeEngine")
    let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Input/Rime-1.17.0", isDirectory: true)
    Task {
      do {
        let handle = try await Task.detached(priority: .userInitiated) {
          try RimeHandle(root: root, user: user)
        }.value
        engine = handle
        state = try handle.apply(0)
        ready = true
      } catch { failure = error.localizedDescription }
    }
  }
  func apply(_ operation: Int32, _ argument: Int32 = 0) throws -> PinyinState {
    guard let engine else {
      throw MTVError.message(failure == nil ? "正在准备中文词库，请稍候再输入" : "中文输入引擎未就绪，可切换英文输入")
    }
    let result = try engine.apply(operation, argument)
    state = result
    return result
  }
}

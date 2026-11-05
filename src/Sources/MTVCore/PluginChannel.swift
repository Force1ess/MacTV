import Darwin
import Foundation

/// Length-prefixed JSON frames. Reject lengths before allocating the body.
public enum PluginChannel {
  public static func write(_ object: [String: Any], to handle: FileHandle, maximum: Int) throws {
    guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw MTVError.message("无法设置安全插件管道") }
    let data = try JSONSerialization.data(withJSONObject: object)
    guard data.count > 0, data.count <= maximum, data.count <= Int(UInt32.max) else { throw MTVError.message("插件通信帧超过大小限制") }
    let value = UInt32(data.count)
    let header = Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    try handle.write(contentsOf: header); try handle.write(contentsOf: data)
  }
  public static func read(from handle: FileHandle, maximum: Int) throws -> [String: Any]? {
    func exact(_ count: Int, allowEOF: Bool) throws -> Data? {
      var data = Data()
      while data.count < count {
        let part = try handle.read(upToCount: min(65_536, count - data.count)) ?? Data()
        if part.isEmpty {
          if allowEOF && data.isEmpty { return nil }
          throw MTVError.message("插件通信帧不完整")
        }
        data.append(part)
      }
      return data
    }
    guard let header = try exact(4, allowEOF: true) else { return nil }
    let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard count > 0, Int(count) <= maximum else { throw MTVError.message("插件通信帧长度无效") }
    guard let body = try exact(Int(count), allowEOF: false),
      let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw MTVError.message("插件通信格式无效") }
    return object
  }
}

import Foundation
import IOKit

public struct TVInputDevice: Codable, Equatable, Sendable {
  public let name: String
  public let kind: String
  public let basis: String
}

public struct InputDeviceInventory: Codable, Sendable {
  public let status: String
  public let devices: [TVInputDevice]
  public let checkedAt: Double
  /// Presence only: never claims remote button mappings or microphone support.
  public var summary: String {
    let usable = devices.filter { ["remote", "trackpad", "controller"].contains($0.kind) }
    if !usable.isEmpty { return L("Connected: \(usable.map(\.name).joined(separator: ", "))") }
    return status == "available" ? LT("尚未识别到遥控器或触控板；连接后会自动更新。") : LT("暂时无法读取设备信息；仍可使用方向键和触控板操作。")
  }
  public static func classify(name: String, usagePage: Int, usage: Int) -> TVInputDevice? {
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = label.lowercased()
    let kind: String, basis: String
    if usagePage == 0x0d && usage == 0x05 {
      kind = "trackpad"; basis = "hid-touchpad-usage"
    } else if ["trackpad", "touchpad", "触控板", "触摸板"].contains(where: lower.contains) {
      kind = "trackpad"; basis = "reported-product-name"
    } else if ["remote", "遥控"].contains(where: lower.contains) {
      kind = "remote"; basis = "reported-product-name"
    } else if usagePage == 1 && [4, 5].contains(usage) {
      kind = "controller"; basis = "hid-controller-usage"
    } else { return nil }
    return TVInputDevice(name: String((label.isEmpty ? (kind == "trackpad" ? "触控板" : "游戏手柄") : label).prefix(120)), kind: kind, basis: basis)
  }
  public static func scan() -> Self {
    var iterator: io_iterator_t = 0
    guard let match = IOServiceMatching("IOHIDDevice"),
      IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
      return Self(status: "unavailable", devices: [], checkedAt: Date().timeIntervalSince1970)
    }
    defer { IOObjectRelease(iterator) }
    var devices: [TVInputDevice] = []
    var seen = Set<String>()
    // Read registry descriptors only. No HID open, input event tap, Bluetooth
    // connection, serial number, address, or Input Monitoring permission.
    for _ in 0..<512 {
      let entry = IOIteratorNext(iterator)
      if entry == 0 { break }
      defer { IOObjectRelease(entry) }
      func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      }
      let name = property("Product") as? String ?? ""
      let page = (property("PrimaryUsagePage") as? NSNumber)?.intValue ?? -1
      let usage = (property("PrimaryUsage") as? NSNumber)?.intValue ?? -1
      if let device = classify(name: name, usagePage: page, usage: usage), seen.insert(device.kind + ":" + device.name).inserted {
        devices.append(device)
      }
    }
    return Self(status: "available", devices: devices.sorted { $0.name < $1.name }, checkedAt: Date().timeIntervalSince1970)
  }
}

// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MTVMPVProbe", platforms: [.macOS("15.0")], targets: [
  .executableTarget(name: "MTVMPVCLIProbe"),
  .target(name: "MPVBridge", publicHeadersPath: "include"),
  .executableTarget(name: "MTVMPVProbe", dependencies: ["MPVBridge"], linkerSettings: [
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../vendor/MPVEngine/lib"])
  ])
])

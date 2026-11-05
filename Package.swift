// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MTV", platforms: [.macOS("15.0")],
  products: [
    .executable(name: "MTV", targets: ["MTV"]),
    .executable(name: "MTVPluginHost", targets: ["MTVPluginHost"]),
    .executable(name: "MTVBenchmark", targets: ["MTVBenchmark"]),
    .executable(name: "MTVChromeBridge", targets: ["MTVChromeBridge"]),
    .executable(name: "mtvctl", targets: ["MTVControl"]),
  ],
  targets: [
    .target(name: "MTVCore", path: "src/Sources/MTVCore"),
    .executableTarget(name: "MTVBenchmark", dependencies: ["MTVCore"], path: "src/Sources/MTVBenchmark"),
    .executableTarget(name: "MTVChromeBridge", path: "src/Sources/MTVChromeBridge"),
    .executableTarget(name: "MacTVMusicLibrary", path: "src/Sources/MacTVMusicLibrary"),
    .executableTarget(name: "MTVControl", dependencies: ["MTVCore"], path: "src/Sources/MTVControl"),
    .executableTarget(name: "MTVStreamingProbe", path: "src/Sources/MTVStreamingProbe"),
    .executableTarget(name: "MTVQuarkProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVQuarkProbe"),
    .target(name: "VLCBridge", path: "src/Sources/VLCBridge", publicHeadersPath: "include"),
    .target(name: "MPVBridge", path: "src/Sources/MPVBridge", publicHeadersPath: "include"),
    .target(name: "RimeBridge", path: "src/Sources/RimeBridge", publicHeadersPath: "include"),
    .executableTarget(name: "MTVRimeProbe", dependencies: ["RimeBridge"], path: "src/Sources/MTVRimeProbe"),
    .executableTarget(name: "MTVLibraryProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVLibraryProbe"),
    .executableTarget(name: "MTVSMBProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVSMBProbe"),
    .executableTarget(name: "MTVMetadataProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVMetadataProbe"),
    .executableTarget(name: "MTVArtworkProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVArtworkProbe"),
    .executableTarget(name: "MTV", dependencies: ["MTVCore", "VLCBridge", "MPVBridge", "RimeBridge"], path: "src/Sources/MTV"),
    .executableTarget(name: "MTVPluginHost", dependencies: ["MTVCore"], path: "src/Sources/MTVPluginHost"),
    .executableTarget(name: "MTVPlaybackProbe", dependencies: [], path: "src/Sources/MTVPlaybackProbe"),
    .executableTarget(name: "MTVVLCProbe", dependencies: ["VLCBridge"], path: "src/Sources/MTVVLCProbe"),
    .executableTarget(name: "MTVAuthProbe", dependencies: ["MTVCore"], path: "src/Sources/MTVAuthProbe"),
    .testTarget(name: "MTVCoreTests", dependencies: ["MTVCore", "MPVBridge"], path: "src/Tests/MTVCoreTests"),
  ]
)

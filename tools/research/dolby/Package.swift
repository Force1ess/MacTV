// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MTVDolbyProbe", platforms: [.macOS("15.0")],
  dependencies: [.package(url: "https://github.com/kingslay/KSPlayer.git", exact: "2.3.4")],
  targets: [.executableTarget(name: "MTVDolbyProbe", dependencies: [.product(name: "KSPlayer", package: "KSPlayer")])])

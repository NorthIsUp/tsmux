// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TSMuxMenu",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(name: "TSMuxMenu", path: "Sources/TSMuxMenu")
  ]
)

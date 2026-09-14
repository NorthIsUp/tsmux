// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TSMuxMenu",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "TSMuxMenu", path: "Sources/TSMuxMenu")
  ]
)

// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ResetRadar", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../packages/RadarCore")],
    targets: [.executableTarget(name: "ResetRadar", dependencies: ["RadarCore"])]
)

// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RadarCore", platforms: [.macOS(.v14)],
    products: [.library(name: "RadarCore", targets: ["RadarCore"])],
    targets: [.target(name: "RadarCore", resources: [.copy("Resources")]), .executableTarget(name: "RadarCoreChecks", dependencies: ["RadarCore"], path: "Tests/RadarCoreTests")]
)

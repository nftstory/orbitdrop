// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrbitDrop",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
        .executable(name: "OrbitDrop", targets: ["OrbitDrop"]),
        .executable(name: "orbitdrop-cli", targets: ["orbitdrop-cli"]),
    ],
    targets: [
        .target(name: "OrbitCore"),
        .executableTarget(name: "OrbitDrop", dependencies: ["OrbitCore"]),
        .executableTarget(name: "orbitdrop-cli", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
    ],
    swiftLanguageVersions: [.v5]
)

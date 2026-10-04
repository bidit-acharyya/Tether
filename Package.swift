// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Dependencies point one way: Storage <- Core <- Sync <- {transports, Sim}.
let package = Package(
    name: "Tether",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "TetherStorage", targets: ["TetherStorage"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
        .library(name: "TetherSync", targets: ["TetherSync"]),
        .library(name: "TetherTransportP2P", targets: ["TetherTransportP2P"]),
        .library(name: "TetherTransportCloudKit", targets: ["TetherTransportCloudKit"]),
        .library(name: "TetherSim", targets: ["TetherSim"]),
    ],
    targets: [
        .target(name: "TetherStorage"),
        .target(name: "TetherCore", dependencies: ["TetherStorage"]),
        .target(name: "TetherSync", dependencies: ["TetherCore"]),
        .target(name: "TetherTransportP2P", dependencies: ["TetherSync"]),
        .target(name: "TetherTransportCloudKit", dependencies: ["TetherSync"]),
        .target(name: "TetherSim", dependencies: ["TetherSync"]),
        .executableTarget(name: "TetherCrashWriter", dependencies: ["TetherStorage"]),

        .testTarget(
            name: "TetherStorageTests", dependencies: ["TetherStorage", "TetherCrashWriter"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore"]),
        .testTarget(name: "TetherSyncTests", dependencies: ["TetherSync"]),
        .testTarget(name: "TetherTransportP2PTests", dependencies: ["TetherTransportP2P"]),
        .testTarget(
            name: "TetherTransportCloudKitTests", dependencies: ["TetherTransportCloudKit"]),
        .testTarget(name: "TetherSimTests", dependencies: ["TetherSim"]),
    ],
    swiftLanguageModes: [.v6]
)

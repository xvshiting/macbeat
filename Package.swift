// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacBeat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacBeat", targets: ["MacBeat"]),
        .executable(name: "MacBeatAgent", targets: ["MacBeatAgent"])
    ],
    targets: [
        .target(name: "MacBeatCore"),
        .executableTarget(name: "MacBeat", dependencies: ["MacBeatCore"]),
        .executableTarget(name: "MacBeatAgent", dependencies: ["MacBeatCore"]),
        .testTarget(name: "MacBeatCoreTests", dependencies: ["MacBeatCore"]),
        .testTarget(name: "MacBeatTests", dependencies: ["MacBeat", "MacBeatCore"])
    ]
)

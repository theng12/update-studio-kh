// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kh-updater",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KHUStub", targets: ["KHUStub"]),
        .library(name: "KHUpdaterCore", targets: ["KHUpdaterCore"]),
        .executable(name: "khu", targets: ["khu"]),
        .executable(name: "khu-stub", targets: ["khu-stub"]),
    ],
    targets: [
        // Deliberately tiny, Foundation-only, no network code: the stub changes rarely.
        .target(name: "KHUStub"),
        .target(name: "KHUpdaterCore", dependencies: ["KHUStub"]),
        .executableTarget(name: "khu", dependencies: ["KHUpdaterCore"]),
        .executableTarget(name: "khu-stub", dependencies: ["KHUStub"]),
        // The suite lives in Tests/Runner and is built by ./build.sh test (it is a custom harness,
        // not XCTest). This target only re-runs build/khu-tests so `swift test` tells the truth
        // instead of failing with a language error (row 20261123-123).
        .testTarget(name: "KHUpdaterTests", dependencies: ["KHUpdaterCore", "KHUStub"],
                    path: "Tests/KHUpdaterTests", exclude: ["Runner"]),
    ]
)

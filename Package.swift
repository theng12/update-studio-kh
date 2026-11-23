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
        // No SwiftPM test target: the suite is ./build.sh test, a custom harness over Tests/Runner.
        // The target that used to be declared here never ran — it had no path, so SwiftPM read the
        // root Tests/ (Python, Objective-C, JS) and failed with "mixed language source files", and
        // the package itself does not build under SwiftPM (`Sources/khu-stub` cannot see
        // `KHUStub`'s types). Rows 20261123-123/-126. A target that cannot run is worse than none.
    ]
)

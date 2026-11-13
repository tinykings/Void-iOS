// swift-tools-version:5.9
// The app's plain-Swift core (Void/Core), built and tested on its own with
// `swift test`, including on Linux. The app itself is built from Void.xcodeproj.
import PackageDescription

let package = Package(
    name: "VoidCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(name: "VoidCore", path: "Void/Core"),
        .testTarget(name: "VoidCoreTests", dependencies: ["VoidCore"], path: "Tests/VoidCoreTests"),
    ]
)

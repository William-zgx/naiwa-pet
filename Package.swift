// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "naiwa-pet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "naiwa", path: "Sources/naiwa"),
        .testTarget(name: "naiwaTests", dependencies: ["naiwa"]),
    ]
)

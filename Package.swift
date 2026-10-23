// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shot",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Shot", path: "Sources/Shot")]
)

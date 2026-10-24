// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shot",
    // Only the macOS this was written on and newer: AppKit treats an app built for an older macOS as an old app and keeps its
    // old behaviours (for example it clips what a view draws outside its own bounds, which cut the cards' shadows).
    platforms: [.macOS("27.0")],
    targets: [.executableTarget(name: "Shot", path: "Sources/Shot")]
)

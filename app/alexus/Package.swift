// swift-tools-version: 5.10
import PackageDescription

// The Mac workspace shares the companion's sources; the iOS app keeps its Xcode target.
let package = Package(
    name: "AlexusKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AlexusKit", targets: ["AlexusKit"])],
    targets: [.target(name: "AlexusKit", path: "Sources", exclude: ["ALEXUSApp.swift"])]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Conveyor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Conveyor", path: "Sources/Conveyor")
    ]
)

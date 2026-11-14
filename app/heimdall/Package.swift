// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Heimdall",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../alexus"),
        // the Shell tab's real terminal (MIT, github.com/migueldeicaza/SwiftTerm); exact version, bumped by hand
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0")
    ],
    targets: [
        .executableTarget(name: "Heimdall", dependencies: ["Belt", .product(name: "AlexusKit", package: "alexus"), .product(name: "SwiftTerm", package: "SwiftTerm")],
                          path: "Sources/Heimdall"),
        // the Conveyor belt (from app/belt-ui), its own module so its names can't clash with Heimdall's
        .target(name: "Belt", path: "Sources/Belt"),
    ]
)

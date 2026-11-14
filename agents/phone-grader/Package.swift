// swift-tools-version: 6.0
//
// PhoneGrader — native macOS app combining ORGRGNRK/phone-grader-bot (grading,
// checklist, listing pipeline) and ORGRGNRK/resale-op-mcp (Atlas floor lookup,
// truthful listing copy). Build with ./build.sh (mirrors ~/Developer/local-ai-app).
import PackageDescription

let package = Package(
    name: "PhoneGrader",
    platforms: [.macOS(.v14), .iOS(.v17)],   // iOS: PhoneGraderCore is shared with iOS/PhoneGraderiOS.xcodeproj
    products: [
        .executable(name: "PhoneGrader", targets: ["PhoneGrader"]),
        .library(name: "PhoneGraderCore", targets: ["PhoneGraderCore"]),
    ],
    targets: [
        // Pure Foundation logic ported from the Python/Node repos. No UI, no network.
        .target(
            name: "PhoneGraderCore",
            path: "Sources/PhoneGraderCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PhoneGrader",
            dependencies: ["PhoneGraderCore"],
            path: "Sources/PhoneGrader",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhoneGraderCoreTests",
            dependencies: ["PhoneGraderCore"],
            path: "Tests/PhoneGraderCoreTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PhoneGraderTests",
            dependencies: ["PhoneGrader"],
            path: "Tests/PhoneGraderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

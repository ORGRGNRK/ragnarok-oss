// swift-tools-version: 6.2
//
// LocalAI — a fully local macOS chat app running MLX models on-device.
//
// Build with ./build.sh (uses xcodebuild so MLX's Metal shaders are compiled
// into mlx-swift_Cmlx.bundle/default.metallib — plain `swift build` cannot do that).

import PackageDescription

let package = Package(
    name: "LocalAI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalAI", targets: ["LocalAI"])
    ],
    dependencies: [
        // LLM libraries (MLXLLM / MLXLMCommon). These moved out of
        // mlx-swift-examples into mlx-swift-lm; 3.x decoupled the tokenizer,
        // so we bring our own (swift-transformers) via a small adapter.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // Core MLX (mlx-swift-lm 3.32.3 requires .upToNextMinor(from: "0.32.3")).
        // Declared directly so we can import MLX for Memory / GPU settings.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // Tokenizer + Jinja chat-template implementation (local folder loading only).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "LocalAI",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "ToolCallParsing",
            ],
            path: "Sources/LocalAI",
            swiftSettings: [
                // Swift 5 language mode: keeps strict-concurrency diagnostics as
                // warnings so a minor Sendable nit in a dependency's API can't
                // break the build.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Pure-Foundation text tool-call recovery (no MLX), unit-testable on its own.
        .target(
            name: "ToolCallParsing",
            path: "Sources/ToolCallParsing",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ToolCallParsingTests",
            dependencies: ["ToolCallParsing"],
            path: "Tests/ToolCallParsingTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

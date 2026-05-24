// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MLXAudio",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Core foundation library
        .library(name: "MLXAudioCore", targets: ["MLXAudioCore"]),

        // Audio codec implementations
        .library(name: "MLXAudioCodecs", targets: ["MLXAudioCodecs"]),

        // Text-to-Speech
        .library(name: "MLXAudioTTS", targets: ["MLXAudioTTS"]),

        // Speech-to-Text (placeholder)
        .library(name: "MLXAudioSTT", targets: ["MLXAudioSTT"]),

        // Speech-to-Speech
        .library(name: "MLXAudioSTS", targets: ["MLXAudioSTS"]),

        // SwiftUI components
        .library(name: "MLXAudioUI", targets: ["MLXAudioUI"]),

        // Legacy combined library (for backwards compatibility)
        .library(
            name: "MLXAudio",
            targets: ["MLXAudioCore", "MLXAudioCodecs", "MLXAudioTTS", "MLXAudioSTT", "MLXAudioSTS", "MLXAudioUI"]
        ),
        .executable(
            name: "mlx-audio-swift-tts",
            targets: ["mlx-audio-swift-tts"],
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git",
            .upToNextMajor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git",
            .upToNextMajor(from: "3.31.3")),
        // swift-tokenizers 0.5.0+ is Swift-only; no traits needed.
        // Pinned to 0.5.x — 0.6.0 swaps the pure-Swift implementation for a
        // UniFFI-based Rust artifactbundle that has known Xcode module-map /
        // compile issues (the 0.6.2 tag ships an explicit "Temporary fix for
        // Xcode builds" commit, 37f999a, the maintainer flagged as a possible
        // Xcode bug). Wait for a stable 0.6.x release without these Xcode
        // compile issues before bumping past 0.5.x.
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git",
            .upToNextMinor(from: "0.5.0")),
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", .upToNextMajor(from: "0.16.0")),
        .package(url: "https://github.com/apple/swift-numerics",
            .upToNextMajor(from: "1.1.1")),
        .package(url: "https://github.com/apple/swift-collections.git",
            .upToNextMajor(from: "1.4.1")),
        .package(url: "https://github.com/apple/swift-crypto.git",
            .upToNextMajor(from: "4.5.0")),
    ],
    targets: [
        // MARK: - MLXAudioCore
        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "SwiftAcervo", package: "SwiftAcervo"),
                // Transitive dependencies for MLX/MLXNN
                .product(name: "Numerics", package: "swift-numerics"),
                .product(name: "RealModule", package: "swift-numerics"),
                .product(name: "ComplexModule", package: "swift-numerics"),
            ],
            path: "Sources/MLXAudioCore",
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-warn-concurrency"], .when(configuration: .debug)),
                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
            ]
        ),

        // MARK: - MLXAudioCodecs
        .target(
            name: "MLXAudioCodecs",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
                .product(name: "SwiftAcervo", package: "SwiftAcervo"),
                // Transitive dependencies for MLXLMCommon
                .product(name: "Numerics", package: "swift-numerics"),
                .product(name: "RealModule", package: "swift-numerics"),
                .product(name: "ComplexModule", package: "swift-numerics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MLXAudioCodecs",
            swiftSettings: [
                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
            ]
        ),

        // MARK: - MLXAudioTTS
        .target(
            name: "MLXAudioTTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "SwiftAcervo", package: "SwiftAcervo"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
                // Transitive dependencies for MLXLMCommon
                .product(name: "Numerics", package: "swift-numerics"),
                .product(name: "RealModule", package: "swift-numerics"),
                .product(name: "ComplexModule", package: "swift-numerics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MLXAudioTTS",
            swiftSettings: [
                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
            ]
        ),

        // MARK: - MLXAudioSTT
        .target(
            name: "MLXAudioSTT",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "SwiftAcervo", package: "SwiftAcervo"),
                .product(name: "Tokenizers", package: "swift-tokenizers"),
                // Transitive dependencies for MLXLMCommon
                .product(name: "Numerics", package: "swift-numerics"),
                .product(name: "RealModule", package: "swift-numerics"),
                .product(name: "ComplexModule", package: "swift-numerics"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MLXAudioSTT",
            swiftSettings: [
                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
            ]
        ),

        // MARK: - MLXAudioSTS
        .target(
            name: "MLXAudioSTS",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioTTS",
                "MLXAudioSTT",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/MLXAudioSTS"
        ),

        // MARK: - MLXAudioUI
        .target(
            name: "MLXAudioUI",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioTTS",
                "MLXAudioSTS",
            ],
            path: "Sources/MLXAudioUI"
        ),

        .executableTarget(
            name: "mlx-audio-swift-tts",
            dependencies: ["MLXAudioCore", "MLXAudioTTS", "MLXAudioSTT"],
            path: "Sources/mlx-audio-swift-tts"
        ),

        // MARK: - Tests
        .testTarget(
            name: "MLXAudioTests",
            dependencies: [
                "MLXAudioCore",
                "MLXAudioCodecs",
                "MLXAudioTTS",
                "MLXAudioSTT",
                "MLXAudioSTS",
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Tests",
            resources: [
                .copy("media")
            ],
            swiftSettings: [
                .define("MLXAUDIO_TELEMETRY_FULL", .when(configuration: .debug)),
            ]
        ),
    ]
)

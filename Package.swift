// swift-tools-version:6.2
import Foundation
import PackageDescription

// In CI we always pin to released remotes. Locally, prefer a sibling checkout
// at ../<name> if present so in-flight changes can be exercised end-to-end
// without publishing a release. Falls back to the remote pin if the sibling
// directory is missing, so fresh clones still build.
//
// When this manifest is evaluated as a transitive dependency inside Xcode's
// `SourcePackages/checkouts/` or SwiftPM's `.build/checkouts/`, every other
// dependency lives as a sibling in the same directory. Treating those as
// in-development local paths produces conflicting package identities, so we
// must skip the sibling shortcut in that context.
let manifestDir = (#filePath as NSString).deletingLastPathComponent
let isSPMCheckout =
  manifestDir.contains("/SourcePackages/checkouts/")
  || manifestDir.contains("/.build/checkouts/")
let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
let useLocalSiblings = !isCI && !isSPMCheckout

func sibling(_ name: String, remote: String, from version: Version) -> Package.Dependency {
  let localPath = "../\(name)"
  if useLocalSiblings && FileManager.default.fileExists(atPath: localPath) {
    return .package(path: localPath)
  }
  return .package(url: remote, .upToNextMajor(from: version))
}

/// Same sibling-priority pattern as ``sibling(_:remote:from:)`` but pins to a
/// remote branch when no local sibling exists. Use only when a temporary
/// pre-release dependency on a feature branch is required; switch back to the
/// version-pinned ``sibling(_:remote:from:)`` once the upstream tags a release.
func sibling(_ name: String, remote: String, branch: String) -> Package.Dependency {
  let localPath = "../\(name)"
  if useLocalSiblings && FileManager.default.fileExists(atPath: localPath) {
    return .package(path: localPath)
  }
  return .package(url: remote, branch: branch)
}

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
        // swift-tokenizers ships the Hugging Face Rust `tokenizers` crate as a
        // binary backend (an SE-0482 `staticLibrary` artifactbundle since
        // 0.7.x; an XCFramework in 0.5.x). 0.6.x briefly had an Xcode module-map
        // bug (the 0.6.2 "Temporary fix for Xcode builds" commit 37f999a) which
        // pinned us to 0.5.x; 0.7.x's artifactbundle resolves and compiles
        // cleanly under xcodebuild, so that blocker is resolved. 0.6.0 also
        // converted the `Tokenizer` protocol to typed throws
        // (`throws(TokenizerError)`); this repo adopts and propagates that (see
        // docs/TODO_TOKENIZERS_0_6_MIGRATION.md). Requires Swift 6.2 / Xcode 26.
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git",
            .upToNextMinor(from: "0.7.1")),
        sibling(
          "SwiftAcervo",
          remote: "https://github.com/intrusive-memory/SwiftAcervo.git",
          from: "0.19.2"),
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

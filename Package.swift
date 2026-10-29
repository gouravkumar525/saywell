// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local LLM cleanup (Qwen 3) on the GPU. Needs xcodebuild for the Metal shaders.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        // mlx-swift-lm 3.x leaves tokenizers/downloaders to these (via MLXHuggingFace macros).
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Parakeet TDT v3 speech recognition on the Neural Engine (B1). Pinned: its API moves fast.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        // In-app updates (B13). Inactive until Info.plist has SUFeedURL + SUPublicEDKey.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.6.4")),
    ],
    targets: [
        .target(
            name: "LocalFlowCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                "LocalFlowCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Sparkle.framework is embedded in Contents/Frameworks by make_app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"]
        ),
    ],
    // Keep the existing code compiling without Swift 6 strict concurrency.
    swiftLanguageModes: [.v5]
)

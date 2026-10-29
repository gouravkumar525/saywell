// swift-tools-version:6.0
// G11: Parakeet TDT v3 (Core ML, via FluidAudio) on the same clips as `LocalFlow --bench-asr`.
// Kept out of the app so LocalFlow doesn't take the dependency unless Parakeet wins.
import PackageDescription

let package = Package(
    name: "ParakeetBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(name: "ParakeetBench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ],
    swiftLanguageModes: [.v5]
)

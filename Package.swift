// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Driftflow",
    platforms: [.macOS("15.0")],
    dependencies: [
        // CoreML / Neural Engine ports of NVIDIA Parakeet. Pinned: the project releases every few days.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "Driftflow",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Driftflow"
        )
    ],
    swiftLanguageModes: [.v5]
)

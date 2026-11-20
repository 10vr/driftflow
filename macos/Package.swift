// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Driftflow",
    platforms: [.macOS("15.0")],
    dependencies: [
        // CoreML / Neural Engine ports of NVIDIA Parakeet. Pinned: the project releases every few days.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
        // Auto-updates (the standard Mac updater).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Catches Objective-C exceptions from Apple APIs that report errors that way (see ObjCSupport.h).
        .target(name: "ObjCSupport", path: "Sources/ObjCSupport"),
        // llama.cpp, prebuilt with its Metal GPU code built in: runs the on-device language models
        // (AI Styles and editing by voice). Pinned to a tested build.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12549/llama-b12549-xcframework.zip",
            checksum: "8c87f76161bb1666e39686702744bb46f3945ce43b49d4be00d75b7001122f42"
        ),
        .executableTarget(
            name: "Driftflow",
            dependencies: [
                "ObjCSupport",
                "llama",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Driftflow",
            // Sparkle.framework and llama.framework are copied into Driftflow.app/Contents/Frameworks by build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)

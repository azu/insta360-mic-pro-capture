// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "insta-360-wav-to-text",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Insta360Core",
            targets: ["Insta360Core"]
        ),
        .executable(
            name: "insta360-wav-to-text",
            targets: ["Insta360WavToText"]
        ),
        .executable(
            name: "insta360-ja-transcribe",
            targets: ["Insta360JaTranscribe"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.12.4"
        ),
    ],
    targets: [
        .target(
            name: "Insta360Core",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "Insta360WavToText",
            dependencies: [
                "Insta360Core",
            ]
        ),
        .executableTarget(
            name: "Insta360JaTranscribe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "Insta360WavToTextTests",
            dependencies: ["Insta360Core", "Insta360WavToText"]
        ),
    ]
)

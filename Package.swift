// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "insta360-mic-pro-capture",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Insta360Core",
            targets: ["Insta360Core"]
        ),
        .executable(
            name: "insta360-mic-pro-capture",
            targets: ["Insta360MicProCapture"]
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
            name: "Insta360MicProCapture",
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
            name: "Insta360MicProCaptureTests",
            dependencies: ["Insta360Core", "Insta360MicProCapture"]
        ),
    ]
)

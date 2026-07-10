// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "AutoScribe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AutoScribe", targets: ["AutoScribeApp"]),
        .library(name: "AutoScribeCore", targets: ["AutoScribeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AutoScribeCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "AutoScribeApp",
            dependencies: ["AutoScribeCore"]
        ),
        .testTarget(
            name: "AutoScribeCoreTests",
            dependencies: ["AutoScribeCore"]
        )
    ]
)

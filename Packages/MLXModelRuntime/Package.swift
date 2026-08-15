// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MLXModelRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MLXModelRuntime", targets: ["MLXModelRuntime"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore"),
        .package(path: "../ModelRuntime"),
        .package(path: "../TokenProfiles"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "MLXModelRuntime",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .testTarget(
            name: "MLXModelRuntimeTests",
            dependencies: [
                "MLXModelRuntime",
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ]
        )
    ]
)

// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CompletionBenchmark",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompletionBenchmark", targets: ["CompletionBenchmark"]),
        .executable(name: "keytype-benchmark", targets: ["keytype-benchmark"])
    ],
    dependencies: [
        .package(path: "../AppCompatibility"),
        .package(path: "../AutocompleteCore"),
        .package(path: "../ConstrainedGeneration"),
        .package(path: "../ModelManagement"),
        .package(path: "../ModelRuntime"),
        .package(path: "../Prompting"),
        .package(path: "../TokenProfiles"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "CompletionBenchmark",
            dependencies: [
                .product(name: "AppCompatibility", package: "AppCompatibility"),
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ConstrainedGeneration", package: "ConstrainedGeneration"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "Prompting", package: "Prompting"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ],
            resources: [
                .copy("Datasets")
            ]
        ),
        .executableTarget(
            name: "keytype-benchmark",
            dependencies: [
                "CompletionBenchmark",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "ModelManagement", package: "ModelManagement"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        ),
        .testTarget(
            name: "CompletionBenchmarkTests",
            dependencies: [
                "CompletionBenchmark",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime")
            ]
        )
    ]
)

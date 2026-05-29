// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModelRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModelRuntime", targets: ["ModelRuntime"]),
        .library(name: "LlamaModelRuntime", targets: ["LlamaModelRuntime"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "ModelRuntime",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        ),
        // llama.cpp xcframework (see ADR-007). The framework is gitignored under Vendor/
        // and must be present locally for the LlamaModelRuntime target to build.
        .binaryTarget(
            name: "llama",
            path: "Vendor/llama.xcframework"
        ),
        .target(
            name: "LlamaModelRuntime",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                "ModelRuntime",
                "llama"
            ]
        ),
        .testTarget(
            name: "ModelRuntimeTests",
            dependencies: [
                "ModelRuntime",
                "LlamaModelRuntime"
            ]
        )
    ]
)

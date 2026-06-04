// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KeyTypeBench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeyTypeBenchCore", targets: ["KeyTypeBench"]),
        .executable(name: "KeyTypeBench", targets: ["KeyTypeBenchCLI"])
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
            name: "KeyTypeBench",
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
            name: "KeyTypeBenchCLI",
            dependencies: [
                "KeyTypeBench",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "ModelManagement", package: "ModelManagement"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        ),
        .testTarget(
            name: "KeyTypeBenchTests",
            dependencies: [
                "KeyTypeBench",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        )
    ]
)

// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ProfileBuilder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "acpf-build", targets: ["acpf-build"]),
        .library(name: "ProfileBuilderCore", targets: ["ProfileBuilderCore"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore"),
        .package(path: "../ModelRuntime"),
        .package(path: "../TokenProfiles"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "ProfileBuilderCore",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        ),
        .executableTarget(
            name: "acpf-build",
            dependencies: [
                "ProfileBuilderCore",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ProfileBuilderTests",
            dependencies: [
                "ProfileBuilderCore",
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "LlamaModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        )
    ]
)

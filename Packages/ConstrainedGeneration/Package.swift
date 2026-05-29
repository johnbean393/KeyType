// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ConstrainedGeneration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConstrainedGeneration", targets: ["ConstrainedGeneration"])
    ],
    dependencies: [
        .package(path: "../AppCompatibility"),
        .package(path: "../AutocompleteCore"),
        .package(path: "../ModelRuntime"),
        .package(path: "../TokenProfiles")
    ],
    targets: [
        .target(
            name: "ConstrainedGeneration",
            dependencies: [
                .product(name: "AppCompatibility", package: "AppCompatibility"),
                .product(name: "AutocompleteCore", package: "AutocompleteCore"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "TokenProfiles", package: "TokenProfiles")
            ]
        )
    ]
)

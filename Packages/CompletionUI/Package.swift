// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CompletionUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompletionUI", targets: ["CompletionUI"])
    ],
    dependencies: [
        .package(path: "../AppCompatibility"),
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "CompletionUI",
            dependencies: [
                .product(name: "AppCompatibility", package: "AppCompatibility"),
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)

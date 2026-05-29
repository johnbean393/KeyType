// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppCompatibility",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppCompatibility", targets: ["AppCompatibility"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "AppCompatibility",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)

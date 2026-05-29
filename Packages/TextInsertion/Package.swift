// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TextInsertion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextInsertion", targets: ["TextInsertion"])
    ],
    dependencies: [
        .package(path: "../AppCompatibility"),
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "TextInsertion",
            dependencies: [
                .product(name: "AppCompatibility", package: "AppCompatibility"),
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)

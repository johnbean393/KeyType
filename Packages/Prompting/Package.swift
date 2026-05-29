// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Prompting",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Prompting", targets: ["Prompting"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "Prompting",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)

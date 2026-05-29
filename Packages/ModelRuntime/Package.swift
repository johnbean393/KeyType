// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModelRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModelRuntime", targets: ["ModelRuntime"])
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
        )
    ]
)

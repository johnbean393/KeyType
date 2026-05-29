// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AutocompleteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutocompleteCore", targets: ["AutocompleteCore"])
    ],
    targets: [
        .target(name: "AutocompleteCore")
    ]
)

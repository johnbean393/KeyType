// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokenProfiles",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenProfiles", targets: ["TokenProfiles"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "TokenProfiles",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        )
    ]
)

// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacContextCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacContextCapture", targets: ["MacContextCapture"])
    ],
    dependencies: [
        .package(path: "../AutocompleteCore")
    ],
    targets: [
        .target(
            name: "MacContextCapture",
            dependencies: [
                .product(name: "AutocompleteCore", package: "AutocompleteCore")
            ]
        ),
        .testTarget(
            name: "MacContextCaptureTests",
            dependencies: ["MacContextCapture"]
        )
    ]
)

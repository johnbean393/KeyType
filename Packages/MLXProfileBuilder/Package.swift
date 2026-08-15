// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MLXProfileBuilder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "acpf-build-mlx", targets: ["acpf-build-mlx"])
    ],
    dependencies: [
        .package(path: "../MLXModelRuntime"),
        .package(path: "../ModelRuntime"),
        .package(path: "../ProfileBuilder"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "acpf-build-mlx",
            dependencies: [
                .product(name: "MLXModelRuntime", package: "MLXModelRuntime"),
                .product(name: "ModelRuntime", package: "ModelRuntime"),
                .product(name: "ProfileBuilderCore", package: "ProfileBuilder"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)

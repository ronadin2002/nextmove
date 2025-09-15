// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nextmove-2",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Add xxHash Swift package for tile hashing
        .package(url: "https://github.com/daisuke-t-jp/xxHash-Swift.git", from: "1.1.1"),
        // .package(url: "https://github.com/metasidd/Orb.git", from: "0.2.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "nextmove-2",
            dependencies: [
                // .product(name: "xxHash_Swift", package: "xxHash-Swift"),
                // .product(name: "Orb", package: "Orb")
            ],
            path: "Sources"
        ),
    ]
)
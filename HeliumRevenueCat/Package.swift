// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HeliumRevenueCat",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "HeliumRevenueCat",
            targets: ["HeliumRevenueCat"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm", .upToNextMajor(from: "5.0.0"))
    ],
    targets: [
        .target(
            name: "HeliumRevenueCat",
            dependencies: [
                .product(name: "Helium", package: "helium-swift"),
                .product(name: "RevenueCat", package: "purchases-ios-spm")
            ]
        )
    ]
)

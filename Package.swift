// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "helium-swift",
    platforms: [
        .iOS(.v14), .macOS(.v11)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Helium",
            targets: ["Helium"]),
        .library(
            name: "HeliumCore",
            targets: ["HeliumCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/onevcat/Kingfisher.git", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/Flight-School/AnyCodable", .upToNextMajor(from: "0.6.0")),
        .package(url: "https://github.com/segmentio/analytics-swift", .upToNextMajor(from: "1.5.11")),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", .upToNextMajor(from: "5.0.2"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HeliumCore",
            dependencies: [
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "Segment", package: "analytics-swift"),
                .product(name: "AnyCodable", package: "AnyCodable"),
                .product(name: "SwiftyJSON", package: "SwiftyJSON")
            ]
        ),
        .target(
            name: "Helium",
            dependencies: ["HeliumCore"]
        ),
        .testTarget(
            name: "helium-swiftTests",
            dependencies: ["Helium"]
        )
    ]
)

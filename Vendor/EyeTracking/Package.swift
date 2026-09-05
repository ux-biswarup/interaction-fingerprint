// swift-tools-version:6.0
// Vendored copy of https://github.com/kyle-fox/ios-eye-tracking (MIT).
// See README.md in this folder for the list of local patches.

import PackageDescription

let package = Package(
    name: "EyeTracking",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "EyeTracking", targets: ["EyeTracking"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "EyeTracking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

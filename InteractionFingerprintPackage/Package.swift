// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "InteractionFingerprintFeature",
    platforms: [.iOS(.v18)],
    products: [
        .library(
            name: "InteractionFingerprintFeature",
            targets: ["InteractionFingerprintFeature"]
        ),
    ],
    dependencies: [
        // ARKit gaze + blend-shape recording, SQLite persistence, JSON export.
        // Vendored and patched copy of kyle-fox/ios-eye-tracking; see Vendor/EyeTracking/README.md.
        .package(path: "../Vendor/EyeTracking"),
    ],
    targets: [
        .target(
            name: "InteractionFingerprintFeature",
            dependencies: [
                .product(name: "EyeTracking", package: "EyeTracking"),
            ]
        ),
        .testTarget(
            name: "InteractionFingerprintFeatureTests",
            dependencies: [
                "InteractionFingerprintFeature"
            ]
        ),
    ]
)

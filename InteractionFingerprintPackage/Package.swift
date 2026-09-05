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
    targets: [
        // No external dependencies yet. The storage milestone will add GRDB directly;
        // Vendor/EyeTracking is kept as reference material, not as a build input.
        // See Vendor/EyeTracking/README.md.
        .target(
            name: "InteractionFingerprintFeature"
        ),
        .testTarget(
            name: "InteractionFingerprintFeatureTests",
            dependencies: [
                "InteractionFingerprintFeature"
            ]
        ),
    ]
)

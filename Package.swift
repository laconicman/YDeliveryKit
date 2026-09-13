// swift-tools-version: 6.2

// The shared foundation below the app and the future widget/Live Activity targets.
// The membership test for anything added here, canonical across README and REVIEW.md:
// code an extension target needs, which cannot import the app. Its practical corollary
// for views: does it render from plain values — no controller, no network, no
// environment? (The wiki once quoted the corollary as the test; it is the consequence,
// not the criterion.)
//
// The Swift settings mirror the app target (project.yml): same language mode, MainActor
// default isolation, and the Approachable Concurrency features the app compiles with —
// one concurrency dialect across app and package.
import PackageDescription

let package = Package(
    name: "YDeliveryKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "YDeliveryKit", targets: ["YDeliveryKit"])
    ],
    dependencies: [
        // Compile-checked SF Symbol names (TechDebt → YD-3); the demo repo already
        // depends on it, so this is alignment, not a new precedent.
        .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "YDeliveryKit",
            dependencies: [
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "YDeliveryKitTests",
            dependencies: ["YDeliveryKit"]
        ),
    ]
)

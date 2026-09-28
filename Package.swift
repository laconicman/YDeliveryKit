// swift-tools-version: 6.2

// The shared foundation below the app and the future widget/Live Activity targets.
// The membership test for anything added here, canonical across README and REVIEW.md:
// code an extension target needs, which cannot import the app. Its practical corollary
// for views: does it render from plain values — no controller, no network, no
// environment? (The wiki once quoted the corollary as the test; it is the consequence,
// not the criterion.)
//
// The Swift settings differ by target — one dialect each, the split being the point:
// `YDeliveryKit` (views, colors, tokens) mirrors the app's MainActor default and
// Approachable Concurrency features; `YDeliveryData` (models, persistence) is
// `.defaultIsolation(nil)` — library code picks no executor for its callers.
import PackageDescription

let package = Package(
    name: "YDeliveryKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        // One product, two targets: the consumer's `import YDeliveryKit` is the
        // whole surface; `YDeliveryData`'s symbols arrive through the umbrella
        // target's re-export (`Sources/YDeliveryKit/Exports.swift`).
        .library(name: "YDeliveryKit", targets: ["YDeliveryData", "YDeliveryKit"])
    ],
    dependencies: [
        // Compile-checked SF Symbol names (TechDebt → YD-3); the demo repo already
        // depends on it, so this is alignment, not a new precedent.
        .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "7.0.0"),
        // The SQLite substrate + CloudKit SyncEngine — extensions read and write
        // through the same `AppDatabase` as the app. sqlite-data re-exports
        // StructuredQueriesSQLite; GRDB carries DatabaseQueue/Row/StatementArguments.
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
        // The @Table macro expands to StructuredQueriesCore calls — the *direct*
        // product link is load-bearing: consumed as a dynamic PackageProduct
        // framework, a transitive reach leaves this target's dylib with undefined
        // symbols. StructuredQueriesSQLite specifically: it builds as a shared
        // framework that re-exports StructuredQueriesCore's symbols, so the Kit,
        // SQLiteData, and the app all resolve ONE `Table` protocol descriptor.
        .package(url: "https://github.com/pointfreeco/swift-structured-queries", from: "0.39.2"),
        // sqlite-data's test seam: `.test` context swaps the SyncEngine's CloudKit
        // state for a mock — schema validation runs without iCloud entitlements.
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.0"),
    ],
    targets: [
        // The data half — models and the persistence substrate. Nonisolated
        // default: library code does not pick an executor for its callers
        // (REVIEW flags `nonisolated` here as a no-op). MainActor default was
        // the package-wide dialect until this target split; the markers that
        // paid for it lived overwhelmingly in these files.
        // `NonisolatedNonsendingByDefault` is deliberately absent: it would pin
        // async methods to the *caller's* executor, and the engine methods
        // (`startSync`/`shareOrder`/`acceptShare`) deadlocked the GRDB queue
        // against the test executor in verification. The unflagged default —
        // generic executor — is the dialect this target wants.
        .target(
            name: "YDeliveryData",
            dependencies: [
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "StructuredQueriesSQLite", package: "swift-structured-queries"),
            ],
            swiftSettings: [
                .defaultIsolation(nil),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        // The UI half — views, colors, layout tokens. MainActor default is the
        // right dialect here; its pure value types still state `nonisolated`
        // (package rule 4 survives inside this target).
        .target(
            name: "YDeliveryKit",
            dependencies: [
                "YDeliveryData",
                .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
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
            dependencies: [
                "YDeliveryKit",
                "YDeliveryData",
                // The substrate suite drives the queue and engine directly —
                // same seams the app's suite used when the code lived there.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
    ]
)

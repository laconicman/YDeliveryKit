import SwiftUI

/// Xcode 27 emits the generated asset-symbol file with `resourceBundle = Bundle.module`
/// under this target's `.defaultIsolation(MainActor)`, so every generated
/// `ColorResource` static is MainActor-isolated — and the `nonisolated` value
/// vocabularies (`OrderStatus.color`, `PointBadge.Role.color`, rule 4) cannot read them.
/// These re-derive the same catalog entries by name through `Bundle.kit`, nonisolated on
/// every toolchain — the same dodge `Bundle.module` already needed (0.3.11). The name
/// strings are the colorset directory names verbatim; a typo is a silent fallback at
/// runtime, so a name belongs here only while its colorset exists in the catalog.
nonisolated extension ColorResource {
    static var kitStatusDraft: Self { .init(name: "statusDraft", bundle: .kit) }
    static var kitStatusSearching: Self { .init(name: "statusSearching", bundle: .kit) }
    static var kitStatusActive: Self { .init(name: "statusActive", bundle: .kit) }
    static var kitStatusDone: Self { .init(name: "statusDone", bundle: .kit) }
    static var kitStatusAttention: Self { .init(name: "statusAttention", bundle: .kit) }
    static var kitStatusCancelled: Self { .init(name: "statusCancelled", bundle: .kit) }

    static var kitPointStart: Self { .init(name: "pointStart", bundle: .kit) }
    static var kitPointMid: Self { .init(name: "pointMid", bundle: .kit) }
    static var kitPointEnd: Self { .init(name: "pointEnd", bundle: .kit) }
    static var kitPlaceReturn: Self { .init(name: "placeReturn", bundle: .kit) }
    static var kitPlaceWarehouse: Self { .init(name: "placeWarehouse", bundle: .kit) }
    static var kitPlacePickup: Self { .init(name: "placePickup", bundle: .kit) }
    static var kitPlaceLocker: Self { .init(name: "placeLocker", bundle: .kit) }
}

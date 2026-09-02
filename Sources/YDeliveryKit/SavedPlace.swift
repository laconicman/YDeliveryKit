import Foundation

/// A place the sender kept: a whole point — address, its parts, the person at the door —
/// plus the name and kind the chips render (Design → "A point carries data, not
/// coordinates"). Picking one fills a route row completely; that is the entire feature.
///
/// Provisional (Phase 2), like `Order`: default role and default options join with the
/// schema research. The `2c` place kinds that are routes' destinations (ПВЗ, постамат)
/// join when the app can actually send to one.
public nonisolated struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// What the chip says — «Дом», «Склад на Невском».
    public var name: String
    public var kind: Kind
    /// The point this place fills into a route row, contact included.
    public var point: RoutePoint

    public nonisolated enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case home
        case warehouse
        case shop
        case other
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, point: RoutePoint) {
        self.id = id
        self.name = name
        self.kind = kind
        self.point = point
    }
}

import Foundation

/// A place the sender kept: a whole point — address, its parts, the person at the door —
/// plus the name and kind the chips render (Design → "A point carries data, not
/// coordinates"). Picking one fills a route row completely; that is the entire feature.
///
/// Provisional (Phase 2), like `Order`: default role and default options join with the
/// schema research. The `2c` place kinds that are routes' destinations (ПВЗ, постамат)
/// join when the app can actually send to one.
public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// What the chip says — «Дом», «Склад на Невском».
    public var name: String
    public var kind: Kind
    /// The point this place fills into a route row, contact included.
    public var point: RoutePoint
    /// Pinned places lead the picker's chip row — pin ≈ favourite, the
    /// sender's-library ruling (doc:Roadmap).
    public var pinned: Bool

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case home
        case warehouse
        case shop
        case other
    }

    public init(id: UUID = UUID(), name: String, kind: Kind, point: RoutePoint,
                pinned: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.point = point
        self.pinned = pinned
    }

    /// Tolerant decode, same rule as `AddressParts.init(from:)`: `places.json`
    /// and `saved-places.json` written before `pinned` existed carry no key, and
    /// a synthesized `decode` would read that as corruption — rescuing bytes
    /// that were never wrong (the substrate never destroys bytes).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        point = try container.decode(RoutePoint.self, forKey: .point)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

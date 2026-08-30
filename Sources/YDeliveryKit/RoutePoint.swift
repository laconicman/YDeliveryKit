import Foundation

/// One stop of an order's route, as the store remembers it: where, spelled how, and who
/// stands at the door. This is what «Repeat» refills and what recents/saved places read —
/// one substrate, not three features (Design → "A point carries data, not coordinates").
///
/// Provisional (Phase 1): address parts, roles, and default options arrive with the
/// Phase-2 schema research; this carries only what the shipped picker can already produce.
public nonisolated struct RoutePoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    /// The address as the courier will read it — the sender may have corrected the
    /// geocoder's proposal, and that correction is exactly what must survive.
    public var address: String

    /// Who hands over or receives at this stop. Optional: the shipped draft flow does
    /// not collect contacts yet (Roadmap → Phase 2 puts them on the draft screen).
    public var contactName: String?
    public var contactPhone: String?

    public init(
        latitude: Double,
        longitude: Double,
        address: String,
        contactName: String? = nil,
        contactPhone: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.contactName = contactName
        self.contactPhone = contactPhone
    }
}

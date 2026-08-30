import Foundation

/// An order as this app remembers it — the unit of work is the order, not the parcel
/// (Design → "The destination & ordering design"). History lives on the device and
/// outlives the vendor's short visibility window, which is why the store, not the API,
/// is the source of truth the UI reads.
///
/// Provisional (Phase 1): price, items, options, the vendor's claim id, and the sender's
/// own fields join with the Phase-2 schema research — this is the substrate's spine, not
/// the final schema.
public nonisolated struct Order: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID

    /// When the sender created it, locally — ordering is meaningful offline history
    /// even before any API acknowledgment exists.
    public var created: Date

    public var status: OrderStatus

    /// Pickup first, drop-offs after, in travel order.
    public var route: [RoutePoint]

    public init(id: UUID = UUID(), created: Date, status: OrderStatus, route: [RoutePoint]) {
        self.id = id
        self.created = created
        self.status = status
        self.route = route
    }
}

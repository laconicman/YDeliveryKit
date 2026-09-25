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

    /// The accepted price, in minor-precision decimal string form exactly as agreed —
    /// additive (Phase-2 slice 6); rows written before it still decode.
    public var price: String?
    public var currency: String?

    /// The delivery class the order was placed with, in the wire's spelling.
    public var tariff: String?

    /// The vendor's claim id — kept for the journal to match against (Phase 3), never
    /// shown above the sender's own vocabulary.
    public var claimID: String?

    /// The assigned courier's name and vehicle («Сергей», «м 234 ор 77») — the
    /// widget/activity's "who to call" line (board `5a`/`5b`). Provider-mirrored:
    /// nil until the provider assigns one.
    public var courierName: String?
    public var courierVehicle: String?

    /// The provider's completion estimate, minutes, as of the last observation —
    /// raw, not a date: the arrival moment is `providerObservedAt + etaMinutes`,
    /// computed at render so a stale estimate never poses as fresh.
    public var etaMinutes: Int?

    /// The wire's own status word (`"performer_found"`, `"delivery_arrived"`) —
    /// mirrored raw so surfaces can speak the phase `status` collapses: «едет
    /// к получателю» and «у двери» are both `.active`. A string, not the
    /// generated type — the wire vocabulary stays a spelling here.
    public var providerStatus: String?

    /// When the provider last reported this state — the "as of" stamp shared
    /// surfaces render (Collaboration → staleness) and the ETA's basis.
    public var providerObservedAt: Date?

    /// The estimated arrival — the provider's own clock, not the read's.
    /// Nil when either side is missing.
    public var etaAt: Date? {
        guard let etaMinutes, let providerObservedAt else { return nil }
        return providerObservedAt.addingTimeInterval(TimeInterval(etaMinutes) * 60)
    }

    public init(
        id: UUID = UUID(),
        created: Date,
        status: OrderStatus,
        route: [RoutePoint],
        price: String? = nil,
        currency: String? = nil,
        tariff: String? = nil,
        claimID: String? = nil,
        courierName: String? = nil,
        courierVehicle: String? = nil,
        etaMinutes: Int? = nil,
        providerStatus: String? = nil,
        providerObservedAt: Date? = nil
    ) {
        self.id = id
        self.created = created
        self.status = status
        self.route = route
        self.price = price
        self.currency = currency
        self.tariff = tariff
        self.claimID = claimID
        self.courierName = courierName
        self.courierVehicle = courierVehicle
        self.etaMinutes = etaMinutes
        self.providerStatus = providerStatus
        self.providerObservedAt = providerObservedAt
    }
}

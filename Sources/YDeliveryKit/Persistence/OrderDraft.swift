import Foundation

/// A parked draft — the sender's half-written order, remembered across quits.
///
/// Device-tier by design: an un-placed order has no provider existence, so the row
/// carries no `providerAccountRef` and the table is never registered with
/// `SyncEngine` — a draft cannot be shared because there is nothing to share *yet*
/// (the same reason `recordOrder` refuses `.draft`). It also survives an identity
/// change: the sender's typing is not provider data, and the account boundary must
/// not eat it.
///
/// One per install: the flow owns a single draft, so `saveDraft` keeps exactly one
/// `orderDrafts` row and replaces its children wholesale. Children mirror the
/// shared tier's shape (`routeStops`/`orderItems`) so promoting a draft to an
/// order at placement is a mechanical copy, and a draft outliving this app's
/// vocabulary still reads row-for-row.
public nonisolated struct OrderDraft: Hashable, Sendable {
    public var id: UUID
    /// When the draft began — kept stable across saves, so "the draft" ages.
    public var createdAt: Date

    // The repeatable options, mirroring `orderOptions` 1:1.
    public var proCourier = false
    public var toDoor = true
    public var thermobag = false
    public var loaders = 0
    public var due: Date?
    public var comment = ""

    /// The class the sender last chose, in the wire's spelling. Prices reprice on
    /// restore — they were never promised to survive — but the *preference* does:
    /// a cargo draft that comes back must not reopen wearing the courier default.
    public var chosenTariff: String?

    /// Route in travel order — array order is the position, as on `Order.route`.
    /// A stop's `point` is nil while it stands unfilled: an added-but-empty row is
    /// part of the draft the sender described, so the hole is kept.
    public var stops: [Stop] = []
    public var items: [Item] = []

    /// «Ваши поля» — answers keyed by field-definition id. Definitions live in the
    /// same database's private tier, so no name/carrier snapshots ride along
    /// (the shared tier's `orderCustomFields` carries them because collaborators
    /// cannot join across the share boundary; a draft never leaves the tier).
    public var fieldValues: [UUID: String] = [:]
    /// Fields the sender disclosed but left unanswered — restored revealed rather
    /// than re-hidden. Answered fields reveal on read regardless (the
    /// seen-before-sent rule), so a stored ref may hold no value.
    public var revealedFieldRefs: Set<UUID> = []

    public init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
    }

    /// One route stop — the draft row's id and role plus an optional filled point.
    public nonisolated struct Stop: Hashable, Sendable, Identifiable {
        public var id: UUID
        /// The draft's role vocabulary is the consumer's (`pickup`/`dropoff`/
        /// `return` and whatever it adds later) — a plain spelling here, the same
        /// posture `Order.tariff` takes toward the wire's words.
        public var role: String
        /// Where and who — `RoutePoint`'s shape verbatim, matching `Order.route`
        /// so the draft promotes without translation. `nil` = the row stands
        /// unfilled; a contact only makes sense at a named door, so nothing else
        /// is carried.
        public var point: RoutePoint?

        public init(id: UUID = UUID(), role: String, point: RoutePoint? = nil) {
            self.id = id
            self.role = role
            self.point = point
        }
    }

    /// One parcel row — mirrors `orderItems`; the journey ends are *values* →
    /// `Stop.id`, nil reading as the route's ends (`*Ref`, not an FK — an item
    /// outliving its named stop must not take the parcel with it on CASCADE).
    public nonisolated struct Item: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name = ""
        public var quantity = 1
        public var weightKg: Double?
        /// Declared value as a decimal-precision string, the same discipline as
        /// `Order.price` — binary float would round money on the way in and out.
        public var cost: String?
        /// ISO 4217 — no default: the writer names its currency, a package
        /// constant would bind the table to one market (as on `OrderItemRow`).
        public var currency: String
        public var sizeLengthCm: Double?
        public var sizeWidthCm: Double?
        public var sizeHeightCm: Double?
        public var pickupStopRef: UUID?
        public var dropoffStopRef: UUID?

        public init(
            id: UUID = UUID(), name: String = "", quantity: Int = 1,
            weightKg: Double? = nil, cost: String? = nil, currency: String,
            sizeLengthCm: Double? = nil, sizeWidthCm: Double? = nil,
            sizeHeightCm: Double? = nil,
            pickupStopRef: UUID? = nil, dropoffStopRef: UUID? = nil
        ) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.weightKg = weightKg
            self.cost = cost
            self.currency = currency
            self.sizeLengthCm = sizeLengthCm
            self.sizeWidthCm = sizeWidthCm
            self.sizeHeightCm = sizeHeightCm
            self.pickupStopRef = pickupStopRef
            self.dropoffStopRef = dropoffStopRef
        }
    }
}

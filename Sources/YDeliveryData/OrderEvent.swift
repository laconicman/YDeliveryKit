import Foundation

/// One change on an order — the history feed every writer appends to
/// (`orderEvents`, shared tier; `providerEvents` before the schema epoch). The flat
/// `Order` carries the *collapsed* status; this stream keeps the provider's own
/// words — `delivery_arrived` is invisible in the six states but is exactly what
/// «курьер у двери» needs — and, from the epoch on, the app's own facts beside them:
/// the `placed` row the ordering flow writes when a claim is accepted, and later a
/// courier's rows for its leg (doc:Schema → "`ProviderEvent` → `OrderEvent`").
///
/// `id` derives at construction — identity is the schema's dedup, never a
/// constraint (doc:Schema): a journal row keys on `orderID ‖ providerEventID`, a
/// sighting on `orderID ‖ providerRevision ‖ providerStatus ‖ routeDigest`, so a
/// replayed page or a re-read of one revision re-derives the same key and merges
/// instead of duplicating, while a corrected route or a later revision is a new
/// fact. `source` is provenance, not identity: a card read and a search read of
/// one revision are one observation. The writer's key id joins both derivations
/// once signing lands (`writerKeyID`, the trust layer's rule 1 — a signed row's
/// identity belongs to one writer); until then the fact id is the row id.
public struct OrderEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var orderID: Order.ID
    /// The logical leg this event belongs to — a value → `legs.ref`, `nil` for the
    /// order's only leg (doc:Schema → "Stage 2"). Always `nil` until legs land.
    public var legRef: UUID?
    /// The feed's own sequence id — `nil` for sightings reported outside a feed
    /// (a search merge, a card fetch).
    public var providerEventID: Int64?
    /// The wire's `revision` — the journal event's own, or the claim card's
    /// `revision` (not its `version`) — part of a sighting's identity and the
    /// derived verdicts' tie-break within one family.
    public var providerRevision: Int64?
    public var at: Date
    /// What changed — `status_changed`, `price_changed`, `sighting`, or the app's
    /// own `placed`.
    public var kind: String
    /// The provider's raw status spelling at this event, when the event is one.
    public var providerStatus: String?
    /// Free-form payload — a refusal reason, a price detail, `placed`'s agreed
    /// claim/tariff/price JSON.
    public var detail: String?
    /// Which feed reported it — `journal`, `search`, `card`, or `app`.
    public var source: String
    /// The digest of the route this event observed — carried by `placed` (the
    /// route as sent) and by sightings (the route as the provider reported it);
    /// the derived route verdict compares the stored stops against the latest
    /// verified one (doc:Collaboration → "`routeDigest`").
    public var routeDigest: String?
    /// The writer's party — a `partyRef`, `nil` until the device knows itself or
    /// on rows written before signing (doc:Schema → "`partyRef`").
    public var authorRef: UUID?

    /// The kinds this app writes. Names rather than a closed enum so a newer
    /// peer's kind decodes instead of failing — the open-vocabulary rule
    /// `OrderMessage.Kind` follows too.
    public enum Kind {
        public static let statusChanged = "status_changed"
        public static let priceChanged = "price_changed"
        public static let sighting = "sighting"
        /// The ordering flow's own fact — the claim as accepted, with the digest
        /// of the route as sent.
        public static let placed = "placed"
    }

    /// The sources this app writes — provenance, never identity.
    public enum Source {
        public static let journal = "journal"
        public static let search = "search"
        public static let card = "card"
        public static let app = "app"
    }

    /// - Parameter providerRevision: the wire's `revision` — the journal event's own,
    ///   the claim card's — part of a sighting's identity: a re-sight of one revision
    ///   is a no-op, a later revision a new fact. Without it (the pre-epoch shape, or
    ///   a caller that has none) every observation of one status keys alike, so a
    ///   status that returns after another one collapses into its first row; the
    ///   mirror still moves and ``AppDatabase/recordEvent(_:)`` still announces it.
    /// - Parameter writerKeyID: the signing key's id, once a writer has one — it
    ///   joins the derivation so two devices recording the same fact write two
    ///   rows rather than one CloudKit record (the trust layer's rule 1).
    public init(
        id: UUID? = nil,
        orderID: Order.ID,
        legRef: UUID? = nil,
        providerEventID: Int64? = nil,
        providerRevision: Int64? = nil,
        at: Date,
        kind: String,
        providerStatus: String? = nil,
        detail: String? = nil,
        source: String,
        routeDigest: String? = nil,
        authorRef: UUID? = nil,
        writerKeyID: String? = nil
    ) {
        if let id {
            self.id = id
        } else {
            self.id = Self.derivedID(
                orderID: orderID, providerEventID: providerEventID,
                providerRevision: providerRevision,
                providerStatus: providerStatus ?? kind,
                routeDigest: routeDigest, writerKeyID: writerKeyID)
        }
        self.orderID = orderID
        self.legRef = legRef
        self.providerEventID = providerEventID
        self.providerRevision = providerRevision
        self.at = at
        self.kind = kind
        self.providerStatus = providerStatus
        self.detail = detail
        self.source = source
        self.routeDigest = routeDigest
        self.authorRef = authorRef
    }

    /// The fact identity (doc:Schema → "Identity on signed tables"): a journal row
    /// by its operation id, a sighting by revision, status and route digest.
    /// Absent components encode as empty strings — the separator can never occur
    /// inside a component (UUIDs, integers, hex digests, status words, key ids).
    /// The id this event would carry under the keyless derivation — what a caller
    /// gets from the initialiser without a `writerKeyID`, and what the writer
    /// re-derives under its own key before inserting (rule 1).
    var keylessDerivedID: UUID {
        Self.derivedID(
            orderID: orderID, providerEventID: providerEventID, providerRevision: providerRevision,
            providerStatus: providerStatus ?? kind, routeDigest: routeDigest, writerKeyID: nil)
    }

    static func derivedID(
        orderID: UUID, providerEventID: Int64?, providerRevision: Int64?,
        providerStatus: String, routeDigest: String?, writerKeyID: String?
    ) -> UUID {
        var components = [orderID.uuidString]
        if let providerEventID {
            components.append(String(providerEventID))
        } else {
            components.append(contentsOf: [
                providerRevision.map(String.init) ?? "",
                providerStatus,
                routeDigest ?? "",
            ])
        }
        if let writerKeyID { components.append(writerKeyID) }
        return .derived(namespace: UUID.DerivedNamespace.providerEvent, components)
    }
}

/// The name the feed carried before the epoch. Source-compatible for one minor;
/// new code names the row what it is.
@available(*, deprecated, renamed: "OrderEvent")
public typealias ProviderEvent = OrderEvent

/// What recording one event changed — the two facts a consumer needs to decide
/// whether the wire said something new. `inserted` is "new to the timeline": a
/// replayed feed id or repeated sighting reports `false`. The stronger
/// `statusAdvanced` is "the mirror's provider word moved to this event's": the
/// transition a notification announces. A replay, a stale event, and a
/// re-sighting of the same word all report `false` — only a genuinely new
/// provider observation of a *different* status advances.
public struct OrderEventOutcome: Sendable, Equatable {
    public var inserted: Bool
    public var statusAdvanced: Bool

    public init(inserted: Bool, statusAdvanced: Bool) {
        self.inserted = inserted
        self.statusAdvanced = statusAdvanced
    }
}

@available(*, deprecated, renamed: "OrderEventOutcome")
public typealias ProviderEventOutcome = OrderEventOutcome

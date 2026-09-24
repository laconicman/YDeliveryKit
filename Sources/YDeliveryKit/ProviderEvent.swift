import Foundation

/// One provider-reported change on an order — the owner-written history feed
/// (`providerEvents`, shared tier). The flat `Order` carries the *collapsed*
/// status; this stream keeps the provider's own words — `delivery_arrived` is
/// invisible in the six states but is exactly what «курьер у двери» needs.
///
/// `id` derives at construction: `orderID ‖ providerEventID` for feed events,
/// `orderID ‖ providerStatus ‖ source` for sightings with no feed id — a
/// replayed event re-derives the same key and merges instead of duplicating
/// (the schema's dedup rule, doc:Schema).
/// What recording one provider event changed — the two facts a consumer needs
/// to decide whether the wire said something new. `inserted` is "new to the
/// timeline": a replayed feed id or repeated sighting reports `false`. The
/// stronger `statusAdvanced` is "the mirror's provider word moved to this
/// event's": the transition a notification announces. A replay, a stale event,
/// and a re-sighting of the same word all report `false` — only a genuinely
/// new provider observation of a *different* status advances.
public nonisolated struct ProviderEventOutcome: Sendable, Equatable {
    public var inserted: Bool
    public var statusAdvanced: Bool

    public init(inserted: Bool, statusAdvanced: Bool) {
        self.inserted = inserted
        self.statusAdvanced = statusAdvanced
    }
}

public nonisolated struct ProviderEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var orderID: Order.ID
    /// The feed's own sequence id — `nil` for sightings reported outside a feed
    /// (a search merge, a card fetch).
    public var providerEventID: Int64?
    public var at: Date
    /// What changed — `status`, `price`, or the provider's own event word.
    public var kind: String
    /// The provider's raw status spelling at this event, when the event is one.
    public var providerStatus: String?
    /// Free-form payload — a refusal reason, a price detail.
    public var detail: String?
    /// Which feed reported it — `journal`, `search`, `card` — so a replayed
    /// sighting derives the same id as its first write.
    public var source: String

    public init(
        id: UUID? = nil,
        orderID: Order.ID, providerEventID: Int64? = nil, at: Date,
        kind: String, providerStatus: String? = nil,
        detail: String? = nil, source: String
    ) {
        if let id {
            self.id = id
        } else if let providerEventID {
            self.id = .derived(namespace: UUID.DerivedNamespace.providerEvent,
                               orderID.uuidString, String(providerEventID))
        } else {
            self.id = .derived(namespace: UUID.DerivedNamespace.providerEvent,
                               orderID.uuidString, providerStatus ?? kind, source)
        }
        self.orderID = orderID
        self.providerEventID = providerEventID
        self.at = at
        self.kind = kind
        self.providerStatus = providerStatus
        self.detail = detail
        self.source = source
    }
}

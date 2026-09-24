import Foundation
import SQLiteData

// The relational contract, verbatim from doc:Schema — every entity carries a stated
// key, stated integrity, and a stated authority. Swift names are `…Row`-suffixed so the
// app's Kit models (`Order`, `SavedPlace`) keep their meaning; the SQL names are the
// contract's own. `SyncEngine` reads foreign keys from the DDL's `REFERENCES` clauses
// (law 3), so `*Ref` columns are typed plain `UUID?`/`TEXT?` — never `SomeTable.ID` —
// which is what makes "not a foreign key" visible in code.

// MARK: - Shared tier (tables:) — the share hierarchy rooted at an order

/// The share root — zero foreign keys by construction. `providerAccountRef` is a
/// *value* column matching `ProviderAccountRow.key`; NULL reads as *unattributed*.
@Table("orders")
nonisolated struct OrderRow: Identifiable {
    let id: UUID
    var createdAt: Date = .init(timeIntervalSince1970: 0)
    var providerAccountRef: String?
    /// No default — the writer names its provider; a package constant would bind
    /// the table to one backend.
    var provider: String
    var lastActivityAt: Date = .init(timeIntervalSince1970: 0)
}

/// The provider mirror, 1:1 — PK is the FK. Owner-sync writes only.
@Table("orderProviderStates")
nonisolated struct OrderProviderStateRow {
    @Column(primaryKey: true)
    var orderID: OrderRow.ID
    var claimID: String?
    var corpClientID: String?
    var status = ""
    var providerStatus: String?
    var providerDetail: String?
    var tariff: String?
    var price: String?
    var currency: String?
    var dueAt: Date?
    var finishedAt: Date?
    var providerObservedAt: Date?
    var mirroredAt: Date = .init(timeIntervalSince1970: 0)
}

/// The repeatable `DeliveryOptions` fields, 1:1 — PK is the FK again.
@Table("orderOptions")
nonisolated struct OrderOptionsRow {
    @Column(primaryKey: true)
    var orderID: OrderRow.ID
    var proCourier = false
    var toDoor = true
    var thermobag = false
    var loaders = 0
    var due: Date?
    var comment = ""
}

/// One stop per row, in travel order.
@Table("routeStops")
nonisolated struct RouteStopRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var position = 0
    var role = ""
    var latitude = 0.0
    var longitude = 0.0
    var address = ""
    var entrance: String?
    var floor: String?
    var apartment: String?
    var intercom: String?
    var contactName: String?
    var contactGivenName: String?
    var contactFamilyName: String?
    var contactPhone: String?
    var contactPhoneExtension: String?
}

/// Parcel contents. `pickupStopRef`/`dropoffStopRef` are *values* → `RouteStopRow.id`;
/// nil reads as the route's ends.
@Table("orderItems")
nonisolated struct OrderItemRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var name = ""
    var quantity = 1
    var weightKg: Double?
    var cost: String?
    /// No default — the writer names its currency; a package constant would bind
    /// the table to one market.
    var currency: String
    var sizeLengthCm: Double?
    var sizeWidthCm: Double?
    var sizeHeightCm: Double?
    var pickupStopRef: UUID?
    var dropoffStopRef: UUID?
}

/// The owner-written provider history feed. `id` is derived — `UUIDv5(orderID ‖
/// providerEventID)` for journal events, `(orderID, providerStatus, source)` for
/// sightings — because `SyncEngine` rejects secondary UNIQUE indexes on synchronized
/// tables at init (spike-verified).
/// A sender-owned field value on the order — shared tier: collaborators read the
/// same «Заказ 4417». `fieldRef` is a value → `CustomFieldDefinitionRow.id`, not
/// an FK: the schema is private-tier, and a value outlives its definition on the
/// `name` snapshot.
@Table("orderCustomFields")
nonisolated struct OrderCustomFieldRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var fieldRef = UUID()
    var name = ""
    var value = ""
}

@Table("providerEvents")
nonisolated struct ProviderEventRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var providerEventID: Int64?
    var at: Date = .init(timeIntervalSince1970: 0)
    var kind = ""
    var providerStatus: String?
    var detail: String?
    var source = ""
}

/// The chat — the only participant-writable stream. `attachmentRef` is a value →
/// `OrderAttachmentRow.id`, same-order rule enforced at the write boundary.
@Table("orderMessages")
nonisolated struct OrderMessageRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var sentAt: Date = .init(timeIntervalSince1970: 0)
    var kind = "text"
    var text: String?
    var attachmentRef: UUID?
    var authorHint: String?
}

/// Attachment metadata; the payload lives one child down so list queries never drag
/// image data.
@Table("orderAttachments")
nonisolated struct OrderAttachmentRow: Identifiable {
    let id: UUID
    var orderID: OrderRow.ID
    var kind = "photo"
    var caption: String?
    var byteSize: Int64?
    var createdAt: Date = .init(timeIntervalSince1970: 0)
    var authorHint: String?
}

@Table("attachmentBlobs")
nonisolated struct AttachmentBlobRow {
    @Column(primaryKey: true)
    var attachmentID: OrderAttachmentRow.ID
    var data = Data()
}

// MARK: - Private tier (privateTables:) — synced to the owner, never shared

/// Provider identity, never secrets — the OAuth token stays in the Keychain.
@Table("providerAccounts")
nonisolated struct ProviderAccountRow {
    @Column(primaryKey: true)
    var key: String  // "<provider>:<accountID>" — the consumer's convention
    /// No default — see `OrderRow.provider`.
    var provider: String
    var corpClientID: String?
    var displayLabel: String?
    var firstSeenAt: Date?
    var lastSeenAt: Date?
}

@Table("orderPrivateStates")
nonisolated struct OrderPrivateStateRow {
    @Column(primaryKey: true)
    var orderID: OrderRow.ID
    var personalNote: String?
    var pinned = false
    var lastSeenActivityAt: Date?
}

/// The named destinations. FK-less: never a share root — sharing is per-order.
@Table("savedPlaces")
nonisolated struct SavedPlaceRow: Identifiable {
    let id: UUID
    var name = ""
    var kind = "other"
    var latitude = 0.0
    var longitude = 0.0
    var address = ""
    var entrance: String?
    var floor: String?
    var apartment: String?
    var intercom: String?
    var contactName: String?
    var contactGivenName: String?
    var contactFamilyName: String?
    var contactPhone: String?
    var contactPhoneExtension: String?
}

/// The sender's field schema («Ваши поля», board `4b`) — private tier: it syncs
/// to the owner's devices but is nobody's share payload. Values it types live in
/// `orderCustomFields` on the order itself.
@Table("customFieldDefinitions")
nonisolated struct CustomFieldDefinitionRow: Identifiable {
    let id: UUID
    var name = ""
    var kind = "text"
    /// JSON array of strings — the packing convention `providerDetail` set.
    var choicesJSON = "[]"
    var isOptional = true
    var isShownByDefault = true
    var carrier = "none"
    var position = 0
}

// MARK: - Device tier — never registered with SyncEngine, never leaves this device.
// The no-secondary-UNIQUE rule governs synchronized tables only, so
// `pendingDiscoveries` may dedupe by UNIQUE(providerAccountRef, claimID).

/// Journal position per provider account — per-device by correctness (two devices
/// sharing a cursor would consume each other's events).
@Table("syncStates")
nonisolated struct SyncStateRow {
    @Column(primaryKey: true)
    var providerAccountRef: String
    var journalCursor: String?
    var historyBackfilled = false
}

/// A feed reported a claim whose card fetch failed — retried until the card lands.
@Table("pendingDiscoveries")
nonisolated struct PendingDiscoveryRow: Identifiable {
    let id: UUID
    var providerAccountRef = ""
    var claimID = ""
    var firstSeenAt: Date = .init(timeIntervalSince1970: 0)
    var lastAttemptAt: Date?
}

/// YD-5's durable home: a POSTed claim whose acceptance answer was lost — reconciled
/// on launch against `claims/search`. `orderRef` is a value → `OrderRow.id`.
@Table("pendingAcceptances")
nonisolated struct PendingAcceptanceRow: Identifiable {
    let id: UUID
    var providerAccountRef = ""
    var claimID: String?
    var orderRef: UUID?
    var createdAt: Date = .init(timeIntervalSince1970: 0)
    var lastCheckedAt: Date?
    var state = "pending"
}

/// Provisional parked draft — an un-placed order has no provider existence, so it is
/// not an `orders` row. Named `OrderDraft`, not `Draft`: `@Table` synthesizes a
/// `.Draft` nested type on every model and a literal `Draft` collides inside the
/// macro (spike-verified).
@Table("orderDrafts")
nonisolated struct OrderDraftRow: Identifiable {
    let id: UUID
    var createdAt: Date = .init(timeIntervalSince1970: 0)
}

@Table("draftStops")
nonisolated struct DraftStopRow: Identifiable {
    let id: UUID
    var draftID: OrderDraftRow.ID
    var position = 0
    var role = ""
}

@Table("draftItems")
nonisolated struct DraftItemRow: Identifiable {
    let id: UUID
    var draftID: OrderDraftRow.ID
    var name = ""
}

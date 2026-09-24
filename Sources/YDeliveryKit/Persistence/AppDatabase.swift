import Foundation
import GRDB
import OSLog
import SQLiteData

/// The SQLite substrate the schema contract (doc:Schema) runs on — one file in the App
/// Group container, one `DatabaseQueue`, opened lazily on first use so `@main`
/// composition stays cheap and an open failure is a stored error to render, never a
/// crash. Replaces the provisional per-file JSON stores behind the same seam.
///
/// `SyncEngine` hangs off the same queue: constructed lazily like the store itself,
/// started once from `@main`. The shared/private/device tier split is the contract's —
/// the lists below are its single source of truth (tests construct the engine through
/// `syncEngine`, never by re-listing tables). Extension targets share this same code —
/// they read and write but never call ``startSync()`` (the engine stays lazy).
public nonisolated final class AppDatabase: Sendable {
    public static let filename = "ydelivery.sqlite"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "YDelivery", category: "persistence")

    private let directory: URL
    private let containerIdentifier: String
    /// The `providerAccountRef` this device reads and writes — the consumer names it
    /// (`"yandex:unattributed"` today, re-keyed when a credential's `corpClientID`
    /// is learned). Nothing here knows which provider stands behind the string.
    private let providerAccountRef: String
    /// The `orders.provider`/`providerAccounts.provider` value, derived from the
    /// account ref's `provider:id` convention — one string names both.
    private var provider: String {
        providerAccountRef.split(separator: ":").first.map(String.init) ?? providerAccountRef
    }
    /// The one-time open result — DDL + legacy migration run inside it. A failure is
    /// captured and rethrown by every access, so a broken store reads as *unavailable*
    /// rather than *empty* (the substrate's could-not-look rule).
    private let opened = OSAllocatedUnfairLock<Result<DatabaseQueue, Error>?>(initialState: nil)
    private let engineOpened = OSAllocatedUnfairLock<Result<SyncEngine, Error>?>(initialState: nil)
    private let syncFailure = OSAllocatedUnfairLock<Error?>(initialState: nil)

    /// Both identifiers are the consumer's to name (Kit rule 2 — nothing here may
    /// bind one app or one provider): the account key feeds `syncStates`, the
    /// container feeds the engine.
    public init(directory: URL, providerAccountRef: String, containerIdentifier: String) {
        self.directory = directory
        self.providerAccountRef = providerAccountRef
        self.containerIdentifier = containerIdentifier
    }

    /// The store rooted in the app's shared container — `nil` when it cannot be
    /// resolved (a state the caller renders, never a crash).
    public static func inAppGroup(
        id: String, providerAccountRef: String, containerIdentifier: String,
        fileManager: FileManager = .default
    ) -> AppDatabase? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: id)
            .map { AppDatabase(
                directory: $0, providerAccountRef: providerAccountRef,
                containerIdentifier: containerIdentifier) }
    }

    /// The open queue — public so consumers can run validated reads (the sync
    /// metadata sidecar queries) and raw SQL where the typed API does not reach.
    /// Writes still belong behind the typed methods: they carry the invariants.
    public var queue: DatabaseQueue {
        get throws {
            try opened.withLock { cell in
                if let cell { return try cell.get() }
                let result = Result {
                    try Self.open(in: directory, providerAccountRef: providerAccountRef,
                                  provider: provider) }
                cell = result
                return try result.get()
            }
        }
    }

    private static func open(in directory: URL, providerAccountRef: String,
                             provider: String) throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: directory.appendingPathComponent(filename).path)
        try db.write { db in try db.execute(sql: ddl) }
        LegacyMigration.run(
            in: directory, db: db, providerAccountRef: providerAccountRef, provider: provider)
        return db
    }

    // MARK: - CloudKit sync

    /// The engine over this queue — lazily constructed like the store itself, its
    /// failure captured the same way. `tables:`/`privateTables:` are the contract's
    /// tiers verbatim (doc:Schema → "Sync tiers"); device-tier tables are simply never
    /// registered, so their writes leave no CloudKit footprint.
    public var syncEngine: SyncEngine {
        get throws {
            try engineOpened.withLock { cell in
                if let cell { return try cell.get() }
                let result = Result {
                    try SyncEngine(
                        for: queue,
                        tables: OrderRow.self, OrderProviderStateRow.self,
                            OrderOptionsRow.self, RouteStopRow.self, OrderItemRow.self,
                            ProviderEventRow.self, OrderMessageRow.self,
                            OrderAttachmentRow.self, AttachmentBlobRow.self,
                        privateTables: ProviderAccountRow.self, OrderPrivateStateRow.self,
                            SavedPlaceRow.self,
                        containerIdentifier: containerIdentifier,
                        startImmediately: false,
                        logger: Logger(
                            subsystem: Bundle.main.bundleIdentifier ?? "YDelivery",
                            category: "CloudKit"))
                }
                cell = result
                return try result.get()
            }
        }
    }

    /// Why sync never started — entitlement absent or engine failed to construct or
    /// start. Stored, not silent: a future surface can render it (same rule as the
    /// open-failure cell above).
    public var syncStartFailure: Error? { syncFailure.withLock { $0 } }

    /// Starts CloudKit sync — idempotent; a second call is a no-op while running.
    /// A build without the iCloud entitlement is logged and recorded, never a crash:
    /// `CKContainer` traps on contact, so the probe runs before the type is touched.
    /// Extension targets share the database but never call this — they read and
    /// write only; sync stays the host app's job.
    public func startSync() async {
        guard iCloudEntitled else {
            let error = SyncStartError.noICloudEntitlement
            Self.logger.error("CloudKit sync skipped — \(error.errorDescription ?? "")")
            syncFailure.withLock { $0 = error }
            return
        }
        do {
            try await syncEngine.start()
            syncFailure.withLock { $0 = nil }
        } catch {
            Self.logger.error("CloudKit sync did not start: \(error.localizedDescription)")
            syncFailure.withLock { $0 = error }
        }
    }

    /// Whether this build may touch CloudKit. `CKContainer` traps when the
    /// entitlement is missing, so the probe runs before the type is contacted.
    /// Device builds carry `embedded.mobileprovision` — its Entitlements dict is
    /// parsed and checked. Simulator/ad-hoc builds have no profile; their runtime
    /// entitlements come from the xcent `YDelivery.entitlements` generates, so
    /// "no profile" reads as *proceed* and `start()` reports any residual failure.
    public var iCloudEntitled: Bool {
        // No profile at all — simulator or ad-hoc — reads as *proceed*: runtime
        // entitlements then come from the xcent generated by YDelivery.entitlements.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        else { return true }
        // A profile that exists but won't parse fails closed — presence without
        // readable Entitlements must not proceed into a possible CKContainer trap.
        guard let profile = Self.provisioningProfile(at: url) else { return false }
        return Self.profileAllowsCloudKit(profile, containerIdentifier: containerIdentifier)
    }

    /// The profile's own claim: CloudKit service enabled and our container listed.
    public static func profileAllowsCloudKit(
        _ profile: [String: Any], containerIdentifier: String
    ) -> Bool {
        guard let entitlements = profile["Entitlements"] as? [String: Any],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String],
              services.contains("CloudKit"),
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        else { return false }
        return containers.contains(containerIdentifier)
    }

    /// `embedded.mobileprovision` is a CMS-signed plist — the Entitlements dict sits
    /// between the XML markers inside.
    private static func provisioningProfile(at url: URL) -> [String: Any]? {
        // ISO-8859-1 maps every byte 1:1 — the CMS envelope's certificate bytes
        // would defeat ASCII decoding and read as *no profile* = proceed (review,
        // PR #39): a byte-preserving decode keeps the parse failure channel honest.
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                from: Data(text[start.lowerBound..<end.upperBound].utf8),
                format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    public enum SyncStartError: LocalizedError {
        case noICloudEntitlement
        public var errorDescription: String? {
            "iCloud entitlement absent — sync stays off rather than trapping in CKContainer"
        }
    }

    /// GRDB binds `UUID` as a 16-byte BLOB; the contract's id columns are TEXT under
    /// `STRICT` — the same lowercase representation StructuredQueries' `.uuid`
    /// binding writes. One funnel keeps handwritten SQL on that representation.
    public static func args(_ values: [(any DatabaseValueConvertible)?]) -> StatementArguments {
        StatementArguments(values.map { ($0 as? UUID)?.uuidString.lowercased() ?? $0 })
    }

    // MARK: - Orders

    /// History as the list reads it: orders joined to their mirrors, stops grouped —
    /// newest first, matching the file store's publish order.
    public func readOrders() throws -> [Order] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o."id", o."createdAt",
                       s."status", s."claimID", s."price", s."currency", s."tariff"
                FROM "orders" o
                LEFT JOIN "orderProviderStates" s ON s."orderID" = o."id"
                ORDER BY o."lastActivityAt" DESC
                """)
            let stops = try Row.fetchAll(db, sql: """
                SELECT * FROM "routeStops" ORDER BY "orderID", "position"
                """).reduce(into: [UUID: [RoutePoint]]()) { grouped, row in
                let orderID: UUID = row["orderID"]
                grouped[orderID, default: []].append(Self.routePoint(row))
            }
            return rows.map { row in
                let id: UUID = row["id"]
                let createdAt: Double = row["createdAt"]
                let status: String? = row["status"]
                return Order(
                    id: id,
                    created: Date(timeIntervalSince1970: createdAt),
                    status: status.flatMap(OrderStatus.init) ?? .draft,
                    route: stops[id] ?? [],
                    price: row["price"],
                    currency: row["currency"],
                    tariff: row["tariff"],
                    claimID: row["claimID"]
                )
            }
        }
    }

    /// The single write funnel for both UI and sync-merge writes. `providerObservedAt`
    /// marks a provider *sighting* — callers that just talked to the wire pass it;
    /// local writes leave it nil so the mirror never fabricates freshness. The mirror
    /// upsert touches only the fields the flat `Order` owns — provider-side columns
    /// (`providerStatus`, `providerDetail`, `dueAt`, `finishedAt`) belong to the sync
    /// writer and survive a UI rewrite.
    public func recordOrder(_ order: Order, providerObservedAt: Date? = nil) throws {
        try queue.write { db in
            try Self.upsert(order, provider: provider, into: db)
            try db.execute(sql: """
                DELETE FROM "routeStops" WHERE "orderID" = ?
                """, arguments: Self.args([order.id]))
            try Self.insertStops(of: order, into: db, upsert: true)
            try db.execute(sql: """
                INSERT INTO "orderProviderStates"
                  ("orderID", "claimID", "status", "tariff", "price", "currency",
                   "providerObservedAt", "mirroredAt")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT("orderID") DO UPDATE SET
                  "claimID" = excluded."claimID",
                  "status" = excluded."status",
                  "tariff" = excluded."tariff",
                  "price" = excluded."price",
                  "currency" = excluded."currency",
                  "providerObservedAt" =
                    COALESCE(excluded."providerObservedAt", "providerObservedAt"),
                  "mirroredAt" = excluded."mirroredAt"
                """, arguments: Self.args([
                    order.id, order.claimID, order.status.rawValue,
                    order.tariff, order.price, order.currency,
                    providerObservedAt?.timeIntervalSince1970,
                    Date.now.timeIntervalSince1970,
                ]))
        }
    }

    /// The migration path — `INSERT OR IGNORE` everywhere: derived child ids make a
    /// retried import reproduce identical keys, so the second pass writes nothing.
    static func insertMigrating(_ order: Order, provider: String, into db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO "orders"
              ("id", "createdAt", "providerAccountRef", "provider", "lastActivityAt")
            VALUES (?, ?, NULL, ?, ?)
            """, arguments: Self.args([order.id, order.created.timeIntervalSince1970,
                            provider, order.created.timeIntervalSince1970]))
        try insertStops(of: order, into: db, upsert: false)
        try db.execute(sql: """
            INSERT OR IGNORE INTO "orderProviderStates"
              ("orderID", "claimID", "status", "tariff", "price", "currency",
               "providerObservedAt", "mirroredAt")
            VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
            """, arguments: Self.args([
                order.id, order.claimID, order.status.rawValue,
                order.tariff, order.price, order.currency,
                Date.now.timeIntervalSince1970,
            ]))
    }

    /// The UI write — a fresh or re-recorded order. The root upsert preserves
    /// `providerAccountRef` (reconciliation's column) but stamps `lastActivityAt`:
    /// a record *is* activity — the file store prepended a re-recorded order, and
    /// this column is the same semantic as a sortable one. `createdAt` keeps the
    /// order's birthday; `lastActivityAt` keeps its place in the list.
    private static func upsert(_ order: Order, provider: String, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO "orders"
              ("id", "createdAt", "providerAccountRef", "provider", "lastActivityAt")
            VALUES (?, ?, NULL, ?, ?)
            ON CONFLICT("id") DO UPDATE SET
              "createdAt" = excluded."createdAt",
              "lastActivityAt" = excluded."lastActivityAt"
            """, arguments: Self.args([order.id, order.created.timeIntervalSince1970,
                            provider, Date.now.timeIntervalSince1970]))
    }

    private static func insertStops(of order: Order, into db: Database, upsert: Bool) throws {
        for (index, point) in order.route.enumerated() {
            let id = UUID.derived(
                namespace: UUID.DerivedNamespace.orderChild,
                order.id.uuidString, "stop", "\(index)")
            try db.execute(sql: """
                INSERT OR \(upsert ? "REPLACE" : "IGNORE") INTO "routeStops"
                  ("id", "orderID", "position", "role",
                   "latitude", "longitude", "address",
                   "entrance", "floor", "apartment", "intercom",
                   "contactName", "contactGivenName", "contactFamilyName",
                   "contactPhone", "contactPhoneExtension")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.args([
                    id, order.id, index,
                    index == 0 ? "pickup" : "dropoff",
                    point.latitude, point.longitude, point.address,
                    point.addressParts?.entrance,
                    point.addressParts?.floor,
                    point.addressParts?.apartment,
                    point.addressParts?.intercom,
                    point.contactName,
                    point.contactGivenName,
                    point.contactFamilyName,
                    point.contactPhone,
                    point.contactPhoneExtension,
                ]))
        }
    }

    private static func routePoint(_ row: Row) -> RoutePoint {
        let entrance: String? = row["entrance"]
        let floor: String? = row["floor"]
        let apartment: String? = row["apartment"]
        let intercom: String? = row["intercom"]
        let parts: AddressParts? = [entrance, floor, apartment, intercom].allSatisfy({ $0 == nil })
            ? nil
            : AddressParts(
                entrance: entrance ?? "", floor: floor ?? "",
                apartment: apartment ?? "", intercom: intercom ?? "")
        return RoutePoint(
            latitude: row["latitude"], longitude: row["longitude"],
            address: row["address"], addressParts: parts,
            contactName: row["contactName"],
            contactGivenName: row["contactGivenName"],
            contactFamilyName: row["contactFamilyName"],
            contactPhone: row["contactPhone"],
            contactPhoneExtension: row["contactPhoneExtension"])
    }

    // MARK: - Saved places

    public func readPlaces() throws -> [SavedPlace] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \"savedPlaces\"").map { row in
                SavedPlace(
                    id: row["id"], name: row["name"],
                    kind: SavedPlace.Kind(rawValue: row["kind"]) ?? .other,
                    point: Self.routePoint(row))
            }
        }
    }

    /// Forgets a place — the `3e` editor's delete. Unknown ids delete nothing and
    /// succeed: forgetting twice is forgetting.
    public func deletePlace(id: SavedPlace.ID) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM \"savedPlaces\" WHERE \"id\" = ?",
                arguments: Self.args([id])
            )
        }
    }

    /// Keeps a place, adopting the stored identity when the destination is already
    /// remembered — the dedupe the file store did read-then-write, now one transaction
    /// (the retry this guards against exists because a read can fail, so memory may
    /// not know the copy already written).
    ///
    /// The adoption applies only to a *new* place: an edit's id is already persisted,
    /// and retargeting it onto a destination another place holds must not hijack the
    /// other row — two places may share a door, and the editor owns its own.
    public func savePlace(_ place: SavedPlace) throws {
        try queue.write { db in
            var place = place
            let existing = try Row.fetchAll(db, sql: "SELECT * FROM \"savedPlaces\"")
            let persisted = existing.contains { ($0["id"] as UUID?) == place.id }
            if !persisted, let match = existing.first(where: {
                Self.routePoint($0).destinationKey == place.point.destinationKey
            }) {
                place.id = match["id"]
            }
            let p = place.point
            try db.execute(sql: """
                INSERT OR REPLACE INTO "savedPlaces"
                  ("id", "name", "kind",
                   "latitude", "longitude", "address",
                   "entrance", "floor", "apartment", "intercom",
                   "contactName", "contactGivenName", "contactFamilyName",
                   "contactPhone", "contactPhoneExtension")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.args([
                    place.id, place.name, place.kind.rawValue,
                    p.latitude, p.longitude, p.address,
                    p.addressParts?.entrance,
                    p.addressParts?.floor,
                    p.addressParts?.apartment,
                    p.addressParts?.intercom,
                    p.contactName,
                    p.contactGivenName,
                    p.contactFamilyName,
                    p.contactPhone,
                    p.contactPhoneExtension,
                ]))
        }
    }

    // MARK: - Sync state (device tier)

    /// The stored state, defaulting to *start over*: absent and unreadable both read
    /// as a first sync — a corrupt cursor is not a credential, and replaying the feed
    /// is the recovery, not the failure. The failure is logged, not silent.
    public func readSyncState() -> SyncState {
        guard let db = try? queue else {
            Self.logger.error("Sync-state read skipped — database unavailable")
            return SyncState(cursor: nil, historyBackfilled: false)
        }
        let state = try? db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT "journalCursor", "historyBackfilled" FROM "syncStates"
                WHERE "providerAccountRef" = ?
                """, arguments: Self.args([providerAccountRef]))
            let pending: [String] = try Row.fetchAll(db, sql: """
                SELECT "claimID" FROM "pendingDiscoveries"
                WHERE "providerAccountRef" = ? ORDER BY "firstSeenAt"
                """, arguments: Self.args([providerAccountRef]))
                .map { $0["claimID"] }
            let cursor: String? = row?["journalCursor"]
            let backfilled: Int64? = row?["historyBackfilled"]
            return SyncState(
                cursor: cursor,
                historyBackfilled: backfilled == 1,
                pendingClaimIDs: pending.isEmpty ? nil : pending)
        }
        if state == nil {
            Self.logger.error("Sync-state read failed; replaying from the start")
        }
        return state ?? SyncState(cursor: nil, historyBackfilled: false)
    }

    /// The cursor, flag, and retry queue land in one transaction — a torn pair
    /// (position advanced, backfill forgotten, or a pending claim dropped) cannot be
    /// observed.
    public func writeSyncState(_ state: SyncState) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO "syncStates"
                  ("providerAccountRef", "journalCursor", "historyBackfilled")
                VALUES (?, ?, ?)
                ON CONFLICT("providerAccountRef") DO UPDATE SET
                  "journalCursor" = excluded."journalCursor",
                  "historyBackfilled" = excluded."historyBackfilled"
                """, arguments: Self.args([
                    providerAccountRef, state.cursor,
                    state.historyBackfilled ? 1 : 0,
                ]))
            let pending = state.pendingClaimIDs ?? []
            if pending.isEmpty {
                try db.execute(sql: """
                    DELETE FROM "pendingDiscoveries" WHERE "providerAccountRef" = ?
                    """, arguments: Self.args([providerAccountRef]))
            } else {
                try db.execute(sql: """
                    DELETE FROM "pendingDiscoveries"
                    WHERE "providerAccountRef" = ?
                      AND "claimID" NOT IN (\(pending.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: Self.args([providerAccountRef] + pending))
            }
            for claimID in pending {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO "pendingDiscoveries"
                      ("id", "providerAccountRef", "claimID", "firstSeenAt")
                    VALUES (?, ?, ?, ?)
                    """, arguments: Self.args([
                        UUID.derived(
                            namespace: UUID.DerivedNamespace.pendingDiscovery,
                            providerAccountRef, claimID),
                        providerAccountRef, claimID,
                        Date.now.timeIntervalSince1970,
                    ]))
            }
        }
    }

    /// The identity boundary — a wipe that fails leaves a stale cursor, which the
    /// provider answers with `invalid_cursor` and the engine replays anyway.
    public func clearSyncState() throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM \"syncStates\" WHERE \"providerAccountRef\" = ?",
                arguments: Self.args([providerAccountRef]))
            try db.execute(
                sql: "DELETE FROM \"pendingDiscoveries\" WHERE \"providerAccountRef\" = ?",
                arguments: Self.args([providerAccountRef]))
        }
    }
}

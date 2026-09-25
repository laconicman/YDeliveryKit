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
        try db.write { db in
            try db.execute(sql: ddl)
            // The schema's late arrivals: CREATE IF NOT EXISTS never adds a
            // column to a table that already exists, so each one lands as a
            // guarded ALTER — the pragma check makes a re-run a no-op.
            for migration in columnMigrations {
                let exists = try Row.fetchOne(db, sql: """
                    SELECT 1 FROM pragma_table_info(?)
                    WHERE "name" = ?
                    """, arguments: [migration.table, migration.column]) != nil
                if !exists {
                    // Constants from `columnMigrations` — interpolated as SQL
                    // text, never bound: ALTER takes identifiers, not arguments.
                    try db.execute(sql: """
                        ALTER TABLE "\(migration.table)"
                        ADD COLUMN "\(migration.column)" \(migration.type)
                        """)
                    // A snapshot column (e.g. `orderCustomFields.carrier`) can
                    // be filled for rows that predate it — same constant-SQL
                    // rule as the ALTER itself.
                    if let backfill = migration.backfill {
                        try db.execute(sql: backfill)
                    }
                }
            }
        }
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
                            OrderCustomFieldRow.self, ProviderEventRow.self,
                            OrderMessageRow.self,
                            OrderAttachmentRow.self, AttachmentBlobRow.self,
                        privateTables: ProviderAccountRow.self, OrderPrivateStateRow.self,
                            SavedPlaceRow.self, CustomFieldDefinitionRow.self,
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
    /// parsed and checked, and its *absence* fails closed: restricted entitlements
    /// like `icloud-services` can only ever be granted through a profile, so a
    /// device binary without one provably has none. Simulator builds are the
    /// converse — Xcode strips restricted entitlements from the signature (the
    /// slot reads empty for every build), so there is nothing left to inspect;
    /// they proceed and `start()` reports any residual failure.
    public var iCloudEntitled: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        else {
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }
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

    /// A read that found bytes it cannot honour — used where the alternative is
    /// the `Row` subscript's `try!` trap on a launch-path read (the draft tier).
    public enum ReadError: LocalizedError {
        case corruptDraftColumn(String)
        public var errorDescription: String? {
            switch self {
            case .corruptDraftColumn(let name):
                "a stored draft column cannot be decoded — \(name)"
            }
        }
    }

    /// A write the store refuses rather than files wrongly.
    public enum WriteError: LocalizedError {
        /// `orders` is the shared tier — a parked draft has no provider existence
        /// and no place in a share tree. `orderDrafts` is its device-tier home.
        case draftHasNoProviderExistence
        /// Two field definitions claiming the same carrier would fight over one
        /// wire slot — the second claim is refused until the first releases it.
        case fieldCarrierTaken
        public var errorDescription: String? {
            switch self {
            case .draftHasNoProviderExistence:
                "a draft is not an order — parked drafts live in orderDrafts, not the shared tier"
            case .fieldCarrierTaken:
                "another field already rides that carrier slot — release it there first"
            }
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
                       s."status", s."claimID", s."price", s."currency", s."tariff",
                       s."courierName", s."courierVehicle", s."etaMinutes",
                       s."providerStatus", s."providerObservedAt"
                FROM "orders" o
                LEFT JOIN "orderProviderStates" s ON s."orderID" = o."id"
                ORDER BY o."lastActivityAt" DESC
                """)
            let stops = try Row.fetchAll(db, sql: """
                SELECT * FROM "routeStops" ORDER BY "orderID", "position"
                """).reduce(into: [UUID: [RoutePoint]]()) { grouped, row in
                let orderID: UUID = row["orderID"]
                grouped[orderID, default: []].append(Self.routeStop(row))
            }
            return rows.map { row in
                let id: UUID = row["id"]
                let createdAt: Double = row["createdAt"]
                let status: String? = row["status"]
                // REAL epoch, optional: `row["x"] as Double?` would bind the
                // subscript's Value to non-optional Double and trap on NULL —
                // the annotation is what makes the decode optional-aware.
                let observedAt: Double? = row["providerObservedAt"]
                return Order(
                    id: id,
                    created: Date(timeIntervalSince1970: createdAt),
                    status: status.flatMap(OrderStatus.init) ?? .draft,
                    route: stops[id] ?? [],
                    price: row["price"],
                    currency: row["currency"],
                    tariff: row["tariff"],
                    claimID: row["claimID"],
                    courierName: row["courierName"],
                    courierVehicle: row["courierVehicle"],
                    etaMinutes: row["etaMinutes"],
                    providerStatus: row["providerStatus"],
                    providerObservedAt: observedAt.map {
                        Date(timeIntervalSince1970: $0)
                    }
                )
            }
        }
    }

    /// The single write funnel for both UI and sync-merge writes. `providerObservedAt`
    /// is the provider's own as-of stamp — the claim's `updatedTs`, not the read's
    /// clock — so a delayed answer can't masquerade as fresher than a journal event
    /// it predates. Callers that just talked to the wire pass it; local writes leave
    /// it nil so the mirror never fabricates freshness. The stamp is monotonic: a
    /// stale merge may not rewind what a fresher one already saw. The mirror upsert
    /// touches only the fields the flat `Order` owns — provider-side columns
    /// (`providerStatus`, `providerDetail`, `dueAt`, `finishedAt`) belong to the sync
    /// writer and survive a UI rewrite.
    ///
    /// `customFields` is tri-state: `nil` (the default) leaves the order's field
    /// values untouched — a status update must not wipe «Заказ 4417» — while a
    /// non-nil value *replaces* the set wholesale (the draft owns all of them).
    ///
    /// A stamped write is a provider *merge*: it applies only while its as-of
    /// stamp is at least as new as the stored observation — a delayed answer
    /// describes older provider truth and must not regress any of the fields it
    /// carries, route included (review, PR #7). Unstamped writes are local
    /// edits and always apply — but only to the fields the sender owns: the
    /// courier/ETA/provider-word columns move on stamped writes alone, so a
    /// stale in-memory `Order` editing a route cannot rewind a fresher
    /// sighting's courier (review, Kit PR #8).
    public func recordOrder(_ order: Order, customFields: [OrderCustomField]? = nil,
                            providerObservedAt: Date? = nil) throws {
        // A draft is not an order — it has no provider existence, and writing one
        // into the shared tier would let SyncEngine offer an unsent draft as a
        // shareable delivery. Parked drafts live in `orderDrafts`, device-tier.
        guard order.status != .draft else { throw WriteError.draftHasNoProviderExistence }
        try queue.write { db in
            if let stamp = providerObservedAt?.timeIntervalSince1970,
               try Bool.fetchOne(db, sql: """
                   SELECT "providerObservedAt" > ? FROM "orderProviderStates"
                   WHERE "orderID" = ?
                   """, arguments: Self.args([stamp, order.id])) == true {
                return
            }
            try Self.upsert(order, provider: provider,
                            providerAccountRef: providerAccountRef, into: db)
            // The visit columns are provider-owned like the courier fields below:
            // an unstamped write is a local edit and must not erase what a
            // sighting recorded at the door — each stop re-adopts the stored
            // visit of the stop at the same destination (matched on
            // `destinationKey`, not position, so a reordered route keeps each
            // stop's record). A stamped merge is provider truth and writes
            // verbatim — it alone may update or clear a visit (review, PR #10).
            var effective = order
            if providerObservedAt == nil {
                effective.route = try Self.reinstatingStoredVisits(
                    of: order, in: db)
            }
            try db.execute(sql: """
                DELETE FROM "routeStops" WHERE "orderID" = ?
                """, arguments: Self.args([order.id]))
            try Self.insertStops(of: effective, into: db, upsert: true)
            if let customFields {
                try db.execute(sql: """
                    DELETE FROM "orderCustomFields" WHERE "orderID" = ?
                    """, arguments: Self.args([order.id]))
                for field in customFields where !field.value.isEmpty {
                    // The row id derives here, never taken from the model: a value
                    // copied off another order (a repeat) carries that order's
                    // derivation, which would collide as a foreign primary key.
                    let rowID = UUID.derived(
                        namespace: UUID.DerivedNamespace.orderCustomField,
                        order.id.uuidString, field.fieldRef.uuidString)
                    try db.execute(sql: """
                        INSERT INTO "orderCustomFields"
                          ("id", "orderID", "fieldRef", "name", "value", "carrier")
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: Self.args([rowID, order.id, field.fieldRef,
                                                   field.name, field.value,
                                                   field.carrier?.rawValue]))
                }
            }
            try db.execute(sql: """
                INSERT INTO "orderProviderStates"
                  ("orderID", "claimID", "status", "tariff", "price", "currency",
                   "courierName", "courierVehicle", "etaMinutes", "providerStatus",
                   "providerObservedAt", "mirroredAt")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT("orderID") DO UPDATE SET
                  "claimID" = excluded."claimID",
                  "status" = excluded."status",
                  "tariff" = excluded."tariff",
                  "price" = excluded."price",
                  "currency" = excluded."currency",
                  -- The courier/ETA/provider-word columns are provider-owned
                  -- mirror values: only a *stamped* merge (a sighting with the
                  -- provider's as-of time) may rewrite them. An unstamped write
                  -- is a local edit — a stale in-memory Order must not regress
                  -- a fresher sighting's courier while keeping its stamp
                  -- (review, Kit PR #8).
                  "courierName" = CASE
                    WHEN excluded."providerObservedAt" IS NOT NULL
                      THEN excluded."courierName" ELSE "courierName" END,
                  "courierVehicle" = CASE
                    WHEN excluded."providerObservedAt" IS NOT NULL
                      THEN excluded."courierVehicle" ELSE "courierVehicle" END,
                  "etaMinutes" = CASE
                    WHEN excluded."providerObservedAt" IS NOT NULL
                      THEN excluded."etaMinutes" ELSE "etaMinutes" END,
                  "providerStatus" = CASE
                    WHEN excluded."providerObservedAt" IS NOT NULL
                      THEN excluded."providerStatus" ELSE "providerStatus" END,
                  "providerObservedAt" = CASE
                    WHEN excluded."providerObservedAt" IS NULL
                      THEN "providerObservedAt"
                    WHEN "providerObservedAt" IS NULL
                      THEN excluded."providerObservedAt"
                    ELSE MAX("providerObservedAt", excluded."providerObservedAt")
                  END,
                  "mirroredAt" = excluded."mirroredAt"
                """, arguments: Self.args([
                    order.id, order.claimID, order.status.rawValue,
                    order.tariff, order.price, order.currency,
                    order.courierName, order.courierVehicle, order.etaMinutes,
                    order.providerStatus,
                    providerObservedAt?.timeIntervalSince1970,
                    Date.now.timeIntervalSince1970,
                ]))
        }
    }

    /// The migration path — `INSERT OR IGNORE` everywhere: derived child ids make a
    /// retried import reproduce identical keys, so the second pass writes nothing.
    /// An order that already exists returns early — replay must not resurrect
    /// children a later edit deleted (the draft-holding file replays every open
    /// until the draft tier lands).
    static func insertMigrating(_ order: Order, provider: String, into db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO "orders"
              ("id", "createdAt", "providerAccountRef", "provider", "lastActivityAt")
            VALUES (?, ?, NULL, ?, ?)
            """, arguments: Self.args([order.id, order.created.timeIntervalSince1970,
                            provider, order.created.timeIntervalSince1970]))
        guard db.changesCount > 0 else { return }  // already migrated — leave it alone
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

    /// The UI write — a fresh or re-recorded order. `providerAccountRef` stamps on
    /// insert — a UI-placed order belongs to the account that placed it — and is
    /// preserved on conflict: re-keying to a learned account is reconciliation's
    /// move, not the writer's. `lastActivityAt` always stamps: a record *is*
    /// activity — the file store prepended a re-recorded order, and this column is
    /// the same semantic as a sortable one. `createdAt` keeps the order's
    /// birthday; `lastActivityAt` keeps its place in the list.
    private static func upsert(_ order: Order, provider: String,
                               providerAccountRef: String, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO "orders"
              ("id", "createdAt", "providerAccountRef", "provider", "lastActivityAt")
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT("id") DO UPDATE SET
              "createdAt" = excluded."createdAt",
              "lastActivityAt" = excluded."lastActivityAt"
            """, arguments: Self.args([order.id, order.created.timeIntervalSince1970,
                            providerAccountRef, provider,
                            Date.now.timeIntervalSince1970]))
    }

    /// The route an unstamped write may safely write: each point's visit is the
    /// stored record for its destination — or nothing. A local write never mints
    /// provider truth: a copied stale visit is dropped where no stored record
    /// matches (a repeated order arrives with visits and leaves with none), and
    /// the stored record wins wherever both exist. Matching is by
    /// `destinationKey` — an address edit drops the visit (the courier's arrival
    /// was at the old address) where a reorder keeps it; two stops at the same
    /// door consume the stored records in position order.
    private static func reinstatingStoredVisits(
        of order: Order, in db: Database
    ) throws -> [RoutePoint] {
        var stored: [String: [RoutePoint.Visit]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT * FROM "routeStops" WHERE "orderID" = ? ORDER BY "position"
            """, arguments: Self.args([order.id])) {
            let stop = Self.routeStop(row)
            if let visit = stop.visit {
                stored[stop.destinationKey, default: []].append(visit)
            }
        }
        guard !stored.isEmpty else {
            return order.route.map { point in
                var point = point
                point.visit = nil
                return point
            }
        }
        return order.route.map { point in
            var point = point
            if var visits = stored[point.destinationKey], !visits.isEmpty {
                point.visit = visits.removeFirst()
                stored[point.destinationKey] = visits
            } else {
                point.visit = nil
            }
            return point
        }
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
                   "building", "entrance", "floor", "apartment", "intercom",
                   "contactName", "contactGivenName", "contactFamilyName",
                   "contactPhone", "contactPhoneExtension",
                   "visitStatus", "visitedAt", "expectedVisitAt")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.args([
                    id, order.id, index,
                    index == 0 ? "pickup" : "dropoff",
                    point.latitude, point.longitude, point.address,
                    point.addressParts?.building,
                    point.addressParts?.entrance,
                    point.addressParts?.floor,
                    point.addressParts?.apartment,
                    point.addressParts?.intercom,
                    point.contactName,
                    point.contactGivenName,
                    point.contactFamilyName,
                    point.contactPhone,
                    point.contactPhoneExtension,
                    point.visit?.status.rawValue,
                    point.visit?.visitedAt?.timeIntervalSince1970,
                    point.visit?.expectedAt?.timeIntervalSince1970,
                ]))
        }
    }

    /// Decodes the columns every point-bearing table shares — `routeStops` and
    /// `savedPlaces` alike. Provider columns stay out: a saved place has no
    /// courier, so this reader never touches a column a caller's schema lacks.
    private static func routePoint(_ row: Row) -> RoutePoint {
        let building: String? = row["building"]
        let entrance: String? = row["entrance"]
        let floor: String? = row["floor"]
        let apartment: String? = row["apartment"]
        let intercom: String? = row["intercom"]
        let parts: AddressParts? = [building, entrance, floor, apartment, intercom]
            .allSatisfy({ $0 == nil })
            ? nil
            : AddressParts(
                building: building ?? "", entrance: entrance ?? "", floor: floor ?? "",
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

    /// A `routeStops` row: the shared point columns plus the provider's visit
    /// record, which only this table carries.
    private static func routeStop(_ row: Row) -> RoutePoint {
        var point = routePoint(row)
        // REAL epoch columns, optional: annotate so the subscript decodes NULL
        // rather than binding Value to non-optional Double and trapping (PR #9).
        let visitedAt: Double? = row["visitedAt"]
        let expectedVisitAt: Double? = row["expectedVisitAt"]
        let visitStatus: String? = row["visitStatus"]
        point.visit = visitStatus.flatMap(RoutePoint.PointVisitStatus.init(rawValue:))
            .map { status in
                RoutePoint.Visit(
                    status: status,
                    visitedAt: visitedAt.map { Date(timeIntervalSince1970: $0) },
                    expectedAt: expectedVisitAt.map { Date(timeIntervalSince1970: $0) })
            }
        return point
    }

    // MARK: - Saved places

    public func readPlaces() throws -> [SavedPlace] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "savedPlaces" ORDER BY "rowid"
                """).map { row in
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
                   "building", "entrance", "floor", "apartment", "intercom",
                   "contactName", "contactGivenName", "contactFamilyName",
                   "contactPhone", "contactPhoneExtension")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.args([
                    place.id, place.name, place.kind.rawValue,
                    p.latitude, p.longitude, p.address,
                    p.addressParts?.building,
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

    // MARK: - Custom fields

    /// The sender's field schema, in definition order — the draft and the settings
    /// list both read it.
    public func fieldDefinitions() throws -> [CustomFieldDefinition] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "customFieldDefinitions" ORDER BY "position"
                """).map { Self.fieldDefinition($0) }
        }
    }

    /// Keeps a definition. Two normalizations happen here rather than at every
    /// editor: a required field is always shown by default (a hidden required
    /// field blocks the order on a value nothing asks for), and each carrier
    /// slot admits one claimant — a second field grabbing «order number» would
    /// fight the first over the same wire key.
    public func saveFieldDefinition(_ definition: CustomFieldDefinition) throws {
        var definition = definition
        if !definition.isOptional { definition.isShownByDefault = true }
        try queue.write { db in
            // The clash check lives inside the write — a read outside the
            // transaction can observe an empty slot that a concurrent save then
            // takes first. Sync-delivered definitions bypass this check (CloudKit
            // writes don't come through here); consumers resolve a duplicated
            // carrier by taking the first claimant in position order, so a
            // cross-device conflict degrades to a stable pick, not corruption.
            if definition.carrier != .none {
                let clash = try Row.fetchOne(db, sql: """
                    SELECT "id" FROM "customFieldDefinitions"
                    WHERE "carrier" = ? AND "id" != ? LIMIT 1
                    """, arguments: Self.args([
                        definition.carrier.rawValue, definition.id])) != nil
                if clash { throw WriteError.fieldCarrierTaken }
            }
            try db.execute(sql: """
                INSERT INTO "customFieldDefinitions"
                  ("id", "name", "kind", "choicesJSON", "isOptional",
                   "isShownByDefault", "carrier", "position")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT("id") DO UPDATE SET
                  "name" = excluded."name", "kind" = excluded."kind",
                  "choicesJSON" = excluded."choicesJSON",
                  "isOptional" = excluded."isOptional",
                  "isShownByDefault" = excluded."isShownByDefault",
                  "carrier" = excluded."carrier", "position" = excluded."position"
                """, arguments: Self.args([
                    definition.id, definition.name, definition.kind.rawValue,
                    String(decoding: (try? JSONEncoder().encode(definition.choices))
                                       ?? Data("[]".utf8), as: UTF8.self),
                    definition.isOptional, definition.isShownByDefault,
                    definition.carrier.rawValue, definition.position,
                ]))
        }
    }

    /// Forgets a definition. Values already on orders keep their `name` snapshot —
    /// deleting «Накладная» from settings cannot rewrite history.
    public func deleteFieldDefinition(id: CustomFieldDefinition.ID) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM \"customFieldDefinitions\" WHERE \"id\" = ?",
                arguments: Self.args([id])
            )
        }
    }

    /// One order's field values, in schema order — orphaned values (their
    /// definition is gone) trail, alphabetically.
    public func orderCustomFields(orderID: Order.ID) throws -> [OrderCustomField] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.* FROM "orderCustomFields" f
                LEFT JOIN "customFieldDefinitions" d ON d."id" = f."fieldRef"
                WHERE f."orderID" = ?
                ORDER BY (d."position" IS NULL), d."position", f."name"
                """, arguments: Self.args([orderID])).map(Self.orderCustomField)
        }
    }

    /// Every stored field value — the search filter and Spotlight read this once
    /// rather than per order.
    public func allOrderCustomFields() throws -> [OrderCustomField] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.* FROM "orderCustomFields" f
                LEFT JOIN "customFieldDefinitions" d ON d."id" = f."fieldRef"
                ORDER BY (d."position" IS NULL), d."position", f."name"
                """).map(Self.orderCustomField)
        }
    }

    private static func fieldDefinition(_ row: Row) -> CustomFieldDefinition {
        let choicesJSON: String = row["choicesJSON"]
        return CustomFieldDefinition(
            id: row["id"], name: row["name"],
            kind: CustomFieldDefinition.Kind(rawValue: row["kind"]) ?? .text,
            choices: (try? JSONDecoder().decode(
                [String].self, from: Data(choicesJSON.utf8))) ?? [],
            isOptional: row["isOptional"], isShownByDefault: row["isShownByDefault"],
            carrier: CustomFieldDefinition.Carrier(rawValue: row["carrier"]) ?? .none,
            position: row["position"])
    }

    private static func orderCustomField(_ row: Row) -> OrderCustomField {
        let carrier: String? = row["carrier"]
        return OrderCustomField(
            orderID: row["orderID"], fieldRef: row["fieldRef"],
            name: row["name"], value: row["value"],
            carrier: carrier.flatMap(CustomFieldDefinition.Carrier.init(rawValue:)))
    }

    /// The sender's own number for an order — the value the order-number carrier
    /// carried — read off the value row's own `carrier` snapshot: the definitions
    /// it would join are private-tier, so a collaborator (or a deleted schema)
    /// has nothing to join against (review, Kit PR #8). The LEFT JOIN supplies
    /// only ordering — definition position first, `fieldRef` as the stable
    /// fallback — so two carrier-conflicting values pick one winner everywhere.
    public func orderNumber(for orderID: Order.ID) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT f."value" FROM "orderCustomFields" f
                LEFT JOIN "customFieldDefinitions" d ON d."id" = f."fieldRef"
                WHERE f."orderID" = ? AND f."carrier" = 'orderNumber'
                ORDER BY (d."position" IS NULL), d."position", f."fieldRef"
                LIMIT 1
                """, arguments: Self.args([orderID]))
        }
    }

    // MARK: - Provider events

    /// Records one provider-reported change. The row's derived id makes a replayed
    /// event a no-op — `inserted` false — so callers can treat insertion as *news*
    /// (a cursor reset replays the feed without re-firing the notification layer).
    /// `statusAdvanced` is the tighter signal the notification layer announces:
    /// true only when a *new* timeline row moved the mirror's provider word to
    /// this event's — a replayed event, a sighting of the same word, a stale
    /// event, or a non-status change does not re-announce what the sender
    /// already saw (review, PR #7).
    ///
    /// The mirror is a separate concern from the timeline, governed by freshness
    /// rather than insertion (review, PR #6): a status-bearing event updates
    /// `providerStatus`/`providerDetail`/`providerObservedAt` only when its stamp
    /// is at least as new as the stored observation — a late-arriving journal
    /// entry still lands on the timeline but cannot regress the mirror. A
    /// repeated *sighting* dedupes out of the timeline yet still refreshes the
    /// mirror, which is how an id-less observation says "still this, as of now".
    /// Status and detail are one pair — a status event without detail clears the
    /// previous observation's, and a non-status event's detail never poses as
    /// the status's own. `lastActivityAt` moves forward only.
    @discardableResult
    public func recordProviderEvent(_ event: ProviderEvent) throws -> ProviderEventOutcome {
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO "providerEvents"
                  ("id", "orderID", "providerEventID", "at", "kind",
                   "providerStatus", "detail", "source")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: Self.args([
                    event.id, event.orderID, event.providerEventID,
                    event.at.timeIntervalSince1970, event.kind,
                    event.providerStatus, event.detail, event.source,
                ]))
            let inserted = db.changesCount > 0
            var statusAdvanced = false
            if event.providerStatus != nil {
                let previous: String? = try Row.fetchOne(db, sql: """
                    SELECT "providerStatus" FROM "orderProviderStates"
                    WHERE "orderID" = ?
                    """, arguments: Self.args([event.orderID]))?["providerStatus"]
                try db.execute(sql: """
                    UPDATE "orderProviderStates" SET
                      "providerStatus" = ?,
                      "providerDetail" = ?,
                      "providerObservedAt" = ?
                    WHERE "orderID" = ?
                      AND ("providerObservedAt" IS NULL OR "providerObservedAt" <= ?)
                    """, arguments: Self.args([
                        event.providerStatus, event.detail,
                        event.at.timeIntervalSince1970, event.orderID,
                        event.at.timeIntervalSince1970,
                    ]))
                // The WHERE gate is the freshness check — a stale event updates
                // zero rows — and only a word that differs from the stored one
                // counts as the status having moved. `inserted` joins the gate
                // because a replayed row can overwrite the mirror at an equal
                // stamp — the feed's tiebreak is arrival order — without being
                // news: re-announcing it would ping-pong banners on a cursor
                // reset (review, PR #7).
                statusAdvanced = inserted && db.changesCount > 0
                    && previous != event.providerStatus
            }
            if inserted {
                try db.execute(sql: """
                    UPDATE "orders" SET "lastActivityAt" = MAX("lastActivityAt", ?)
                    WHERE "id" = ?
                    """, arguments: Self.args([event.at.timeIntervalSince1970, event.orderID]))
            }
            return ProviderEventOutcome(
                inserted: inserted, statusAdvanced: statusAdvanced)
        }
    }

    /// One order's provider history, oldest first — the timeline the detail view
    /// and the notification audit trail both read.
    public func providerEvents(orderID: Order.ID) throws -> [ProviderEvent] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "providerEvents"
                WHERE "orderID" = ? ORDER BY "at", "id"
                """, arguments: Self.args([orderID])).map(Self.providerEvent)
        }
    }

    private static func providerEvent(_ row: Row) -> ProviderEvent {
        ProviderEvent(
            id: row["id"],
            orderID: row["orderID"],
            providerEventID: row["providerEventID"],
            at: Date(timeIntervalSince1970: row["at"]),
            kind: row["kind"],
            providerStatus: row["providerStatus"],
            detail: row["detail"],
            source: row["source"])
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
            try db.execute(
                sql: "DELETE FROM \"pendingAcceptances\" WHERE \"providerAccountRef\" = ?",
                arguments: Self.args([providerAccountRef]))
        }
    }

    // MARK: - Pending acceptances (device tier) — YD-5's durable half

    /// What a drain can still do with a pending row.
    public nonisolated enum PendingAcceptanceOutcome {
        /// The card answered nothing yet — stay pending, stamp the check.
        case checked
        /// The claim materialized — link the order it became; a resolution
        /// without the order it landed as would be an unexplained close.
        case resolved(orderID: UUID)
        /// The claim provably never materialized within the drain's window —
        /// stop asking, keep the audit row.
        case lapsed
    }

    /// A claim this device accepted and never saw the answer to — the durable half
    /// of the ordering flow's `unresolved` state. Only `state = 'pending'` rows
    /// with a claim id surface here; a `nil`-claimID row (a create whose answer
    /// was lost before the id was known) is audit-only — nothing can fetch it.
    public nonisolated struct PendingAcceptance: Hashable, Sendable {
        public let claimID: String
        /// When the loss was recorded — the drain's staleness measure.
        public let createdAt: Date
        /// Which lost answer this row is — a re-note is a new attempt, and a
        /// drain outcome must name its attempt so a stale result cannot close
        /// a newer one (review, PR #12).
        public let attempt: Int
    }

    /// Acceptance attempted, answer lost — remembered so a force-quit cannot
    /// forget a claim that may be spending money (YD-5). Idempotent on
    /// `account ‖ claimID`: noting the same lost answer twice is one row, and a
    /// re-noted row is a *new* attempt — fresh `createdAt`, fresh counter —
    /// because the latest owed answer, not the first, is what the drain owes.
    public func noteUnresolvedAcceptance(claimID: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO "pendingAcceptances"
                  ("id", "providerAccountRef", "claimID", "createdAt", "state")
                VALUES (?, ?, ?, ?, 'pending')
                ON CONFLICT("id") DO UPDATE SET
                  "state" = 'pending', "orderRef" = NULL, "lastCheckedAt" = NULL,
                  "createdAt" = excluded."createdAt",
                  "attempt" = "pendingAcceptances"."attempt" + 1
                """, arguments: Self.args([
                    UUID.derived(
                        namespace: UUID.DerivedNamespace.pendingAcceptance,
                        providerAccountRef, claimID),
                    providerAccountRef, claimID,
                    Date.now.timeIntervalSince1970,
                ]))
        }
    }

    /// The pending rows, oldest first. Absent reads empty; an *unreadable* queue
    /// logs rather than posing as empty — the drain otherwise skips the only
    /// reconciliation this launch may get (same posture ``readSyncState`` takes).
    public func pendingAcceptances() -> [PendingAcceptance] {
        guard let rows = try? queue.read({ db in
            try Row.fetchAll(db, sql: """
                SELECT "claimID", "createdAt", "attempt" FROM "pendingAcceptances"
                WHERE "providerAccountRef" = ? AND "state" = 'pending'
                  AND "claimID" IS NOT NULL
                ORDER BY "createdAt"
                """, arguments: Self.args([providerAccountRef]))
        }) else {
            Self.logger.error("Pending-acceptance read failed; drain skips this pass")
            return []
        }
        return rows.map {
            PendingAcceptance(
                claimID: $0["claimID"],
                createdAt: Date(timeIntervalSince1970: $0["createdAt"]),
                attempt: $0["attempt"])
        }
    }

    /// The drain's bookkeeping for one read row — matched on the *attempt*, not
    /// the claim: a re-note landing between the drain's read and this write is a
    /// new owed answer a stale outcome must not close (review, PR #12).
    /// `resolved` and `lapsed` are terminal for the poll — the row itself stays:
    /// this table is the audit of "we POSTed and never saw the answer", and a
    /// deleted row is a forgotten attempt, not a resolved one.
    public func markPendingAcceptance(
        _ pending: PendingAcceptance, as outcome: PendingAcceptanceOutcome
    ) throws {
        let (state, orderID): (String, UUID?) = switch outcome {
        case .checked: ("pending", nil)
        case .lapsed: ("lapsed", nil)
        case .resolved(let orderID): ("resolved", orderID)
        }
        try queue.write { db in
            try db.execute(sql: """
                UPDATE "pendingAcceptances" SET
                  "state" = ?,
                  "orderRef" = COALESCE(?, "orderRef"),
                  "lastCheckedAt" = ?
                WHERE "providerAccountRef" = ? AND "claimID" = ?
                  AND "state" = 'pending' AND "attempt" = ?
                """, arguments: Self.args([
                    state, orderID, Date.now.timeIntervalSince1970,
                    providerAccountRef, pending.claimID, pending.attempt,
                ]))
        }
    }

    // MARK: - Drafts

    /// The parked draft, written whole — one row, children replaced per save.
    /// At most one `orderDrafts` row ever exists: the flow owns a single draft,
    /// so the write also clears strays a crash or bug could have left — the
    /// singleton is enforced here, not assumed from the caller's discipline.
    public func saveDraft(_ draft: OrderDraft) throws {
        try queue.write { db in
            // `PRAGMA foreign_keys` is off (GRDB's default), so CASCADE never
            // fires — children die explicitly, as `recordOrder`'s stops do.
            for table in [DraftStopRow.tableName, DraftItemRow.tableName,
                          DraftCustomFieldRow.tableName] {
                try db.execute(
                    sql: "DELETE FROM \"" + table + "\" WHERE \"draftID\" != ?",
                    arguments: Self.args([draft.id]))
            }
            try db.execute(sql: """
                DELETE FROM "orderDrafts" WHERE "id" != ?
                """, arguments: Self.args([draft.id]))
            try db.execute(sql: """
                INSERT INTO "orderDrafts"
                  ("id", "createdAt", "proCourier", "toDoor", "thermobag",
                   "loaders", "due", "comment", "chosenTariff")
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT("id") DO UPDATE SET
                  "proCourier" = excluded."proCourier",
                  "toDoor" = excluded."toDoor",
                  "thermobag" = excluded."thermobag",
                  "loaders" = excluded."loaders",
                  "due" = excluded."due",
                  "comment" = excluded."comment",
                  "chosenTariff" = excluded."chosenTariff"
                """, arguments: Self.args([
                    draft.id, draft.createdAt.timeIntervalSince1970,
                    draft.proCourier, draft.toDoor, draft.thermobag,
                    draft.loaders, draft.due?.timeIntervalSince1970,
                    draft.comment, draft.chosenTariff,
                ]))
            // Children rewrite wholesale: the draft is a document, not a delta —
            // a stop removed mid-edit must not outlive its row.
            for table in [DraftStopRow.tableName, DraftItemRow.tableName,
                          DraftCustomFieldRow.tableName] {
                try db.execute(
                    sql: "DELETE FROM \"" + table + "\" WHERE \"draftID\" = ?",
                    arguments: Self.args([draft.id]))
            }
            for (position, stop) in draft.stops.enumerated() {
                let point = stop.point
                try db.execute(sql: """
                    INSERT INTO "draftStops"
                      ("id", "draftID", "position", "role",
                       "latitude", "longitude", "address",
                       "building", "entrance", "floor", "apartment", "intercom",
                       "contactName", "contactGivenName", "contactFamilyName",
                       "contactPhone", "contactPhoneExtension")
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: Self.args([
                        stop.id, draft.id, position, stop.role,
                        point?.latitude, point?.longitude, point?.address,
                        point?.addressParts?.building,
                        point?.addressParts?.entrance, point?.addressParts?.floor,
                        point?.addressParts?.apartment, point?.addressParts?.intercom,
                        point?.contactName, point?.contactGivenName,
                        point?.contactFamilyName, point?.contactPhone,
                        point?.contactPhoneExtension,
                    ]))
            }
            for item in draft.items {
                try db.execute(sql: """
                    INSERT INTO "draftItems"
                      ("id", "draftID", "name", "quantity", "weightKg", "cost",
                       "currency", "sizeLengthCm", "sizeWidthCm", "sizeHeightCm",
                       "pickupStopRef", "dropoffStopRef")
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: Self.args([
                        item.id, draft.id, item.name, item.quantity,
                        item.weightKg, item.cost, item.currency,
                        item.sizeLengthCm, item.sizeWidthCm, item.sizeHeightCm,
                        item.pickupStopRef, item.dropoffStopRef,
                    ]))
            }
            // An answered field and a merely-disclosed one share the row — NULL
            // `value` marks the latter (the draft remembers the disclosure, not
            // just the typing).
            for (fieldRef, value) in draft.fieldValues {
                try db.execute(sql: """
                    INSERT INTO "draftCustomFields" ("id", "draftID", "fieldRef", "value")
                    VALUES (?, ?, ?, ?)
                    """, arguments: Self.args([
                        UUID.derived(namespace: UUID.DerivedNamespace.draftCustomField,
                                     draft.id.uuidString, fieldRef.uuidString),
                        draft.id, fieldRef, value,
                    ]))
            }
            for fieldRef in draft.revealedFieldRefs where draft.fieldValues[fieldRef] == nil {
                try db.execute(sql: """
                    INSERT INTO "draftCustomFields" ("id", "draftID", "fieldRef", "value")
                    VALUES (?, ?, ?, NULL)
                    """, arguments: Self.args([
                        UUID.derived(namespace: UUID.DerivedNamespace.draftCustomField,
                                     draft.id.uuidString, fieldRef.uuidString),
                        draft.id, fieldRef,
                    ]))
            }
        }
    }

    /// The parked draft, if one exists. Throws rather than posing as empty: an
    /// unreadable draft must not masquerade as none, or the caller's next save
    /// could collapse bytes it never got to read (the load-bearing difference
    /// from `pendingAcceptances`, where a skipped pass only delays a retry).
    /// Reads go through ``column(_:in:as:)`` rather than the subscript — a draft
    /// is read on every launch, so a corrupt row must throw, not trap the app.
    public func currentDraft() throws -> OrderDraft? {
        try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM "orderDrafts" ORDER BY "createdAt" DESC LIMIT 1
                """) else { return nil }
            let draftID: UUID = try Self.column("id", in: row)
            let createdAt: Double = try Self.column("createdAt", in: row)
            var draft = OrderDraft(id: draftID,
                                   createdAt: Date(timeIntervalSince1970: createdAt))
            draft.proCourier = try Self.column("proCourier", in: row)
            draft.toDoor = try Self.column("toDoor", in: row)
            draft.thermobag = try Self.column("thermobag", in: row)
            draft.loaders = try Self.column("loaders", in: row)
            draft.due = try Self.columnIfPresent("due", in: row)
                .map { Date(timeIntervalSince1970: $0) }
            draft.comment = try Self.column("comment", in: row)
            draft.chosenTariff = try Self.columnIfPresent("chosenTariff", in: row)
            draft.stops = try Row.fetchAll(db, sql: """
                SELECT * FROM "draftStops" WHERE "draftID" = ? ORDER BY "position"
                """, arguments: Self.args([draftID])).map { row in
                try OrderDraft.Stop(
                    id: Self.column("id", in: row),
                    role: Self.column("role", in: row),
                    point: Self.draftPoint(row))
            }
            draft.items = try Row.fetchAll(db, sql: """
                SELECT * FROM "draftItems" WHERE "draftID" = ? ORDER BY "rowid"
                """, arguments: Self.args([draftID])).map { row in
                try OrderDraft.Item(
                    id: Self.column("id", in: row),
                    name: Self.column("name", in: row),
                    quantity: Self.column("quantity", in: row),
                    weightKg: Self.columnIfPresent("weightKg", in: row),
                    cost: Self.columnIfPresent("cost", in: row),
                    currency: Self.column("currency", in: row),
                    sizeLengthCm: Self.columnIfPresent("sizeLengthCm", in: row),
                    sizeWidthCm: Self.columnIfPresent("sizeWidthCm", in: row),
                    sizeHeightCm: Self.columnIfPresent("sizeHeightCm", in: row),
                    pickupStopRef: Self.columnIfPresent("pickupStopRef", in: row),
                    dropoffStopRef: Self.columnIfPresent("dropoffStopRef", in: row))
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT "fieldRef", "value" FROM "draftCustomFields"
                WHERE "draftID" = ?
                """, arguments: Self.args([draftID])) {
                let fieldRef: UUID = try Self.column("fieldRef", in: row)
                draft.revealedFieldRefs.insert(fieldRef)
                if let value: String = try Self.columnIfPresent("value", in: row) {
                    draft.fieldValues[fieldRef] = value
                }
            }
            return draft
        }
    }

    /// The draft is consumed — placed, or its claim's fate handed to the
    /// pending-acceptance drain. One row ever exists, so the delete names no id:
    /// whatever row is parked is the current draft's. Children die explicitly —
    /// `PRAGMA foreign_keys` is off (GRDB's default), so CASCADE never fires.
    public func deleteDrafts() throws {
        try queue.write { db in
            for table in [DraftStopRow.tableName, DraftItemRow.tableName,
                          DraftCustomFieldRow.tableName] {
                try db.execute(sql: "DELETE FROM \"" + table + "\"")
            }
            try db.execute(sql: "DELETE FROM \"orderDrafts\"")
        }
    }

    /// A `draftStops` row's point: same column names as the shared tier, but
    /// nullable — an unfilled stop is position + role + NULLs. A row with
    /// partial coordinates is corrupt and reads as unfilled rather than
    /// trusting half an address.
    private static func draftPoint(_ row: Row) throws -> RoutePoint? {
        guard let latitude: Double = try columnIfPresent("latitude", in: row),
              let longitude: Double = try columnIfPresent("longitude", in: row),
              let address: String = try columnIfPresent("address", in: row)
        else { return nil }
        let building: String? = try columnIfPresent("building", in: row)
        let entrance: String? = try columnIfPresent("entrance", in: row)
        let floor: String? = try columnIfPresent("floor", in: row)
        let apartment: String? = try columnIfPresent("apartment", in: row)
        let intercom: String? = try columnIfPresent("intercom", in: row)
        let parts: AddressParts? = [building, entrance, floor, apartment, intercom]
            .allSatisfy({ $0 == nil })
            ? nil
            : AddressParts(
                building: building ?? "", entrance: entrance ?? "", floor: floor ?? "",
                apartment: apartment ?? "", intercom: intercom ?? "")
        return RoutePoint(
            latitude: latitude, longitude: longitude,
            address: address, addressParts: parts,
            contactName: try columnIfPresent("contactName", in: row),
            contactGivenName: try columnIfPresent("contactGivenName", in: row),
            contactFamilyName: try columnIfPresent("contactFamilyName", in: row),
            contactPhone: try columnIfPresent("contactPhone", in: row),
            contactPhoneExtension: try columnIfPresent("contactPhoneExtension", in: row))
    }

    /// `row["x"]` is `try!` inside — fine for the shared tier's reads, but the
    /// draft is read on every launch, where a corrupt row would trap the app at
    /// every start. These read through `DatabaseValue` so failure surfaces as an
    /// error the caller can log and step around; the next save collapses the row.
    private static func column<T: DatabaseValueConvertible>(
        _ name: String, in row: Row, as type: T.Type = T.self
    ) throws -> T {
        let value: DatabaseValue = row[name]
        guard let decoded = T.fromDatabaseValue(value) else {
            throw ReadError.corruptDraftColumn(name)
        }
        return decoded
    }

    private static func columnIfPresent<T: DatabaseValueConvertible>(
        _ name: String, in row: Row, as type: T.Type = T.self
    ) throws -> T? {
        let value: DatabaseValue = row[name]
        if value.isNull { return nil }
        guard let decoded = T.fromDatabaseValue(value) else {
            throw ReadError.corruptDraftColumn(name)
        }
        return decoded
    }
}

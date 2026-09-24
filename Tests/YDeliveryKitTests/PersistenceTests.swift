import Dependencies
import Foundation
import GRDB
import SQLiteData
import Testing
import YDeliveryKit

/// The substrate's own suite — the code moved here, so its contract coverage did too.
/// What stays app-side is only what needs the app's own identity: the entitlement
/// probe (Bundle.main's real profile) and the consumer's container/account constants.
@Suite("Persistence")
struct PersistenceTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A test account and mock container — nothing here touches a real CloudKit
    /// identity; the consumer names its own.
    private func makeDatabase() -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test")
    }

    // MARK: Schema validation — the contract's DDL against SyncEngine.init

    /// `.test` context swaps the engine's CloudKit state for a mock — no container
    /// (which would trap without iCloud entitlements) — while `validateSchema()` still
    /// runs on the real DDL: FK graph, uniqueness, and PK rules exercised for real.
    /// The engine comes from `AppDatabase.syncEngine` itself, so the production tier
    /// lists are what get validated — no second copy to drift.
    @Test("SyncEngine accepts the production schema")
    func syncEngineAcceptsTheSchema() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
    }

    /// The review's central finding, pinned: a secondary UNIQUE on a synchronized
    /// table is a `SyncEngine.init` rejection — dedup is derived identity, never a
    /// constraint. If a future schema edit adds one, this fails loudly.
    @Test("A non-PK unique index on a synchronized table is rejected")
    func secondaryUniqueIsRejected() throws {
        let database = makeDatabase()
        try database.queue.write { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX "eventDedup" ON "providerEvents"
                  ("orderID", "providerEventID")
                """)
        }
        withDependencies {
            $0.context = .test
        } operation: {
            #expect(throws: (any Error).self) {
                _ = try database.syncEngine
            }
        }
    }

    // MARK: Sync tiers — what the engine leaves a footprint for

    /// The metadatabase ATTACHes to our queue as `sqlitedata_icloud`; writes through
    /// that same connection fire the triggers `setUpSyncEngine` installed, leaving one
    /// `sqlitedata_icloud_metadata` row per synchronized record. This is the tier
    /// split made observable: shared + private rows appear, device rows never do.
    private func syncedRecordNames(_ database: AppDatabase) throws -> [String] {
        try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "recordName" FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata"
                """)
        }
    }

    private func parentRecordNames(_ database: AppDatabase) throws -> [String?] {
        try database.queue.read { db in
            try Optional<String>.fetchAll(db, sql: """
                SELECT "parentRecordName"
                FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata"
                ORDER BY "recordName"
                """)
        }
    }

    @Test("An order write leaves a share-tree footprint — root and children tagged")
    func sharedWritesLeaveMetadata() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine  // triggers install at construction
        }
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-1")
        try database.recordOrder(order)

        let names = try syncedRecordNames(database)
        #expect(names.contains { $0.hasSuffix(":orders") })
        #expect(names.contains { $0.hasSuffix(":routeStops") })
        #expect(names.contains { $0.hasSuffix(":orderProviderStates") })
        let parents = try parentRecordNames(database)
        #expect(parents.contains { $0?.hasSuffix(":orders") == true },
                "children name the order record as parent — the share edge is real")
    }

    @Test("A saved place syncs privately — footprint exists, never shared")
    func privateTierLeavesMetadata() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        try database.savePlace(SavedPlace(
            name: "Склад", kind: .warehouse,
            point: RoutePoint(latitude: 59, longitude: 30, address: "Невский, 100")))

        #expect(try syncedRecordNames(database).contains { $0.hasSuffix(":savedPlaces") })
    }

    @Test("Device-tier writes leave no CloudKit footprint at all")
    func deviceTierLeavesNoMetadata() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        try database.writeSyncState(.init(
            cursor: "eyJ-opaque", historyBackfilled: true,
            pendingClaimIDs: ["claim-missed"]))

        let names = try syncedRecordNames(database)
        #expect(!names.contains { $0.hasSuffix(":syncStates") })
        #expect(!names.contains { $0.hasSuffix(":pendingDiscoveries") },
                "the journal cursor and retry queue are per-device by correctness")
    }

    // MARK: Engine start — failure surfacing

    /// The gate must pass on every host we ship or test on. On the simulator there
    /// is no embedded profile — and there never could be a meaningful signature
    /// check either, since Xcode strips restricted entitlements from simulator
    /// signatures. On device, a missing profile fails closed.
    @Test("The entitlement gate passes on this host")
    func iCloudEntitlementGatePasses() {
        #expect(makeDatabase().iCloudEntitled)
    }

    @Test("The provisioning-profile check reads CloudKit service and container")
    func profileCheckReadsCloudKit() {
        let container = "iCloud.test.Container"
        let good: [String: Any] = ["Entitlements": [
            "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
            "com.apple.developer.icloud-container-identifiers": [container],
        ]]
        #expect(AppDatabase.profileAllowsCloudKit(good, containerIdentifier: container))
        #expect(!AppDatabase.profileAllowsCloudKit(
            ["Entitlements": [:]], containerIdentifier: container),
                "a profile without iCloud must fail the gate")
        #expect(!AppDatabase.profileAllowsCloudKit(["Entitlements": [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.other.App"],
        ]], containerIdentifier: container), "a foreign container must fail the gate")
    }

    @Test("startSync runs the engine against the mock container")
    func startSyncStartsTheEngine() async throws {
        let database = makeDatabase()
        await withDependencies {
            $0.context = .test
        } operation: {
            await database.startSync()
            let engine = try? database.syncEngine
            #expect(engine?.isRunning == true)
            #expect(database.syncStartFailure == nil)
        }
    }

    @Test("A schema the engine rejects surfaces as a stored failure, not a crash")
    func failedEngineStartIsStored() async throws {
        let database = makeDatabase()
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX "eventDedup" ON "providerEvents"
                  ("orderID", "providerEventID")
                """)
        }
        await withDependencies {
            $0.context = .test
        } operation: {
            await database.startSync()
            #expect(database.syncStartFailure != nil,
                    "rejection is a rendered state, never a silent no-op")
        }
    }

    // MARK: Derived identity

    @Test("Derived ids are stable and distinct per input")
    func derivedIDsAreDeterministic() {
        let a = UUID.derived(
            namespace: UUID.DerivedNamespace.providerEvent, "order-1", "42")
        let b = UUID.derived(
            namespace: UUID.DerivedNamespace.providerEvent, "order-1", "42")
        let c = UUID.derived(
            namespace: UUID.DerivedNamespace.providerEvent, "order-1", "43")
        #expect(a == b, "same inputs, same id — replay re-produces the key")
        #expect(a != c)
    }

    // MARK: Store round-trips

    @Test("An order round-trips with its route, contacts, and mirror fields")
    func orderRoundTrips() throws {
        let database = makeDatabase()
        var point = RoutePoint(
            latitude: 55.75, longitude: 37.61, address: "Тверская, 6",
            contactName: "Иван Петров", contactPhone: "+79123456789")
        point.addressParts = AddressParts(entrance: "2", apartment: "12")
        let order = Order(
            created: .now, status: .active,
            route: [point, RoutePoint(latitude: 59, longitude: 30, address: "Невский, 100")],
            price: "850.00", currency: "RUB", tariff: "express", claimID: "claim-9")

        try database.recordOrder(order)
        let stored = try #require(database.readOrders().first)

        #expect(stored.id == order.id)
        #expect(stored.status == .active)
        #expect(stored.claimID == "claim-9")
        #expect(stored.price == "850.00")
        #expect(stored.route.count == 2)
        #expect(stored.route[0].addressParts?.apartment == "12")
        #expect(stored.route[0].contactPhone == "+79123456789")
        #expect(stored.route[1].address == "Невский, 100")
    }

    @Test("A re-recorded order keeps one row and one set of stops")
    func recordIsIdempotent() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-1")

        try database.recordOrder(order)
        var updated = order
        updated.status = .cancelled
        try database.recordOrder(updated)

        let stored = try database.readOrders()
        #expect(stored.count == 1)
        #expect(stored.first?.status == .cancelled)
        let stopCount = try database.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"routeStops\"")!
        }
        #expect(stopCount == 1, "derived stop ids replace in place, never duplicate")
    }

    /// The file store prepended a re-recorded order; `lastActivityAt` carries that
    /// semantic into the contract — a touched order surfaces, never sinks.
    @Test("A re-recorded older order returns to the top of history")
    func reRecordSurfacesTheOrder() throws {
        let database = makeDatabase()
        let old = Order(
            created: .init(timeIntervalSince1970: 1_700_000_000), status: .done,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "Старый")])
        let new = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "Новый")])
        try database.recordOrder(old)
        try database.recordOrder(new)
        #expect(try database.readOrders().map(\.id) == [new.id, old.id])

        var reopened = old
        reopened.status = .active
        try database.recordOrder(reopened)

        #expect(try database.readOrders().map(\.id) == [old.id, new.id],
                "activity order, not birthday order — a sync-touched old order leads")
    }

    /// The shared tier is for provider-ordered deliveries only — a parked draft has
    /// no provider existence, and SyncEngine must never be offered one.
    @Test("A draft cannot enter the shared tier")
    func draftIsRefused() throws {
        let database = makeDatabase()
        let draft = Order(
            created: .now, status: .draft,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")])

        #expect(throws: AppDatabase.WriteError.draftHasNoProviderExistence) {
            try database.recordOrder(draft)
        }
        #expect(try database.readOrders().isEmpty, "nothing was written")
    }

    /// A UI-placed order belongs to the account that placed it — the ref stamps on
    /// insert so reconciliation can name the owner when accounts diverge.
    @Test("A recorded order stamps this device's account")
    func recordStampsTheAccount() throws {
        let database = makeDatabase()
        try database.recordOrder(Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")]))

        let ref: String? = try database.queue.read {
            let row = try Row.fetchOne($0, sql: """
                SELECT "providerAccountRef" FROM "orders"
                """)
            return row?["providerAccountRef"]
        }
        #expect(ref == "test:unattributed")
    }

    @Test("A UI rewrite preserves a sync-stamped providerObservedAt")
    func uiRewritePreservesObservedAt() throws {
        let database = makeDatabase()
        let order = Order(created: .now, status: .active, route: [], claimID: "claim-7")

        try database.recordOrder(order, providerObservedAt: .now)
        var updated = order
        updated.price = "900.00"
        try database.recordOrder(updated)  // no sighting — a local write

        let observed: Double? = try database.queue.read {
            let row = try Row.fetchOne($0, sql: """
                SELECT "providerObservedAt" FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
            return row?["providerObservedAt"]
        }
        #expect(observed != nil, "a sighting survives the local write — freshness is never erased")
    }

    /// The stamp is the provider's own as-of time, so it is monotonic: a merge
    /// whose claim predates what the journal already saw must not rewind the
    /// clock and gate later events out of the status mirror.
    @Test("A stale merge cannot rewind providerObservedAt")
    func staleMergeCannotRewindObservedAt() throws {
        let database = makeDatabase()
        let order = Order(created: .now, status: .active, route: [], claimID: "claim-8")
        let fresh = Date.now
        let stale = fresh.addingTimeInterval(-600)

        try database.recordOrder(order, providerObservedAt: fresh)
        var refetched = order
        refetched.price = "910.00"
        try database.recordOrder(refetched, providerObservedAt: stale)

        let observed: Double? = try database.queue.read {
            let row = try Row.fetchOne($0, sql: """
                SELECT "providerObservedAt" FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
            return row?["providerObservedAt"]
        }
        #expect(observed == fresh.timeIntervalSince1970,
                "the fresher stamp holds — a stale answer describes older provider truth")
    }

    // MARK: Saved places — the editor's semantics

    /// The 3e editor's hazard, pinned: retargeting a saved place onto a destination
    /// another place holds must not adopt the other's row — the original stays and
    /// the other is untouched.
    @Test("Editing a place onto another's destination hijacks nothing")
    func editKeepsItsOwnRow() throws {
        let database = makeDatabase()
        let first = SavedPlace(
            name: "Дом", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6"))
        let second = SavedPlace(
            name: "Склад", kind: .warehouse,
            point: RoutePoint(latitude: 59, longitude: 30, address: "Невский, 100"))
        try database.savePlace(first)
        try database.savePlace(second)

        var edited = second
        edited.point = RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6")
        try database.savePlace(edited)

        let places = try database.readPlaces()
        #expect(places.count == 2, "an edit writes its own row — no merge, no theft")
        #expect(places.contains { $0.id == first.id && $0.name == "Дом" })
        #expect(places.contains { $0.id == second.id && $0.name == "Склад" })
    }

    /// The retry the dedupe exists for: a *new* save over an already-remembered
    /// destination adopts the stored identity — memory may not know the copy landed.
    @Test("A new save over a remembered destination adopts its identity")
    func newSaveAdoptsExistingIdentity() throws {
        let database = makeDatabase()
        let first = SavedPlace(
            name: "Дом", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6"))
        try database.savePlace(first)

        let again = SavedPlace(
            name: "Дом подъезд 2", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6"))
        try database.savePlace(again)

        let places = try database.readPlaces()
        #expect(places.count == 1)
        #expect(places.first?.name == "Дом подъезд 2",
                "adoption keeps one row and takes the newest words")
    }

    // MARK: Sync state

    @Test("The sync state round-trips and clears at the identity boundary")
    func syncStateRoundTrips() throws {
        let database = makeDatabase()
        #expect(database.readSyncState() == .init(cursor: nil, historyBackfilled: false),
                "absent reads as first sync, never a crash")

        try database.writeSyncState(.init(cursor: "eyJ-opaque", historyBackfilled: true,
                                          pendingClaimIDs: ["claim-missed"]))
        #expect(database.readSyncState() == .init(
            cursor: "eyJ-opaque", historyBackfilled: true,
            pendingClaimIDs: ["claim-missed"]))

        try database.clearSyncState()
        #expect(database.readSyncState() == .init(cursor: nil, historyBackfilled: false),
                "a wiped state reads fresh — the next token inherits nothing")
    }

    // MARK: Migration — the JSON stores into tables

    private func write(_ data: Data, named name: String) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func legacyOrdersJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode([
            Order(
                created: .init(timeIntervalSince1970: 1_700_000_000), status: .done,
                route: [RoutePoint(latitude: 55, longitude: 37, address: "Старый заказ")],
                price: "500.00", currency: "RUB", claimID: "legacy-1")
        ])
    }

    @Test("orders.json migrates: rows land, source renamed, freshness stays NULL")
    func ordersMigrate() throws {
        try write(legacyOrdersJSON(), named: "orders.json")
        let database = makeDatabase()

        let stored = try #require(database.readOrders().first)
        #expect(stored.claimID == "legacy-1")
        #expect(stored.route.map(\.address) == ["Старый заказ"])

        // Honest freshness: the file's one mtime is not a per-order sighting.
        let mirror = try #require(database.queue.read {
            try Row.fetchOne($0, sql: """
                SELECT "providerObservedAt" FROM "orderProviderStates"
                """)
        })
        let observed: Double? = mirror["providerObservedAt"]
        #expect(observed == nil,
                "migrated rows are unattributed history — NULL until a provider sighting")
        let orderAccountRef: String? = try database.queue.read {
            let row = try Row.fetchOne($0, sql: "SELECT \"providerAccountRef\" FROM \"orders\"")
            return row?["providerAccountRef"]
        }
        #expect(orderAccountRef == nil, "legacy rows seed NULL — never invent an owner")

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("orders.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("orders.migrated-") },
                "the source is renamed in place — kept, not deleted")
    }

    @Test("A retried migration writes nothing twice — derived keys absorb it")
    func migrationRetryIsIdempotent() throws {
        let json = try legacyOrdersJSON()
        try write(json, named: "orders.json")
        _ = try makeDatabase().queue

        // Crash-in-the-window replay: the file is still there (rename never ran).
        try write(json, named: "orders.json")
        _ = try makeDatabase().queue

        let database = makeDatabase()
        #expect(try database.readOrders().count == 1)
        let stopCount = try database.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"routeStops\"")!
        }
        #expect(stopCount == 1, "a second pass reproduces identical keys and writes nothing")
    }

    /// The review's three-horned edge, resolved by separation: drafts in the legacy
    /// file are refused by the shared tier, so they are written to a durable
    /// `orders.pending-*.json` sibling before the source renames — the committed
    /// file leaves rotation entirely (no replay can resurrect an edited or deleted
    /// order), and the refused bytes stay findable for a future draft migration.
    @Test("Drafts separate to a pending sibling — the committed file is done")
    func draftsSeparateToPendingFile() throws {
        let encoder = JSONEncoder()
        let json = try encoder.encode([
            Order(created: .now, status: .done,
                  route: [RoutePoint(latitude: 55, longitude: 37, address: "Старый"),
                          RoutePoint(latitude: 59, longitude: 30, address: "Невский")]),
            Order(created: .now, status: .draft,
                  route: [RoutePoint(latitude: 55, longitude: 37, address: "Черновик")]),
        ])
        try write(json, named: "orders.json")
        let database = makeDatabase()

        let stored = try #require(database.readOrders().first)
        #expect(stored.status == .done && stored.route.count == 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains("orders.json"), "the committed file leaves rotation")
        #expect(names.contains { $0.hasPrefix("orders.migrated-") })
        let pending = try #require(names.first { $0.hasPrefix("orders.pending-") },
                                   "refused rows get a durable sibling, not the void")
        let pendingOrders = try JSONDecoder().decode(
            [Order].self, from: Data(contentsOf: directory.appendingPathComponent(pending)))
        #expect(pendingOrders.map(\.status) == [.draft],
                "the pending file carries exactly what the shared tier refused")

        // Reopening cannot replay: nothing answers to orders.json anymore.
        var edited = stored
        edited.route = [stored.route[0]]
        try database.recordOrder(edited)
        _ = try makeDatabase().queue
        #expect(try makeDatabase().readOrders().first?.route.count == 1)
    }

    /// The same content must never produce a second pending file — the pending
    /// name is content-derived and byte-compared, so a retried separation rewrites
    /// nothing. The test reproduces the input shape an interrupted rename leaves
    /// (source still answering to orders.json, pending sibling already present);
    /// the rename failure itself is not injectable through the public API.
    @Test("A retried separation reuses its pending file")
    func pendingWriteIsIdempotent() throws {
        let encoder = JSONEncoder()
        let json = try encoder.encode([
            Order(created: .now, status: .draft,
                  route: [RoutePoint(latitude: 55, longitude: 37, address: "Черновик")]),
        ])
        try write(json, named: "orders.json")
        _ = try makeDatabase().queue
        let first = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("orders.pending-") }
        try write(json, named: "orders.json")  // the source as a retry would find it
        _ = try makeDatabase().queue
        let second = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("orders.pending-") }
        #expect(first == second && second.count == 1,
                "one pending artifact per content — no accumulation, no overwrite")
    }

    @Test("A corrupt orders.json is rescued, not destroyed and not blocking")
    func corruptSourceIsRescued() throws {
        try write(Data("not json".utf8), named: "orders.json")
        let database = makeDatabase()

        #expect(try database.readOrders().isEmpty,
                "a corrupt file reads as empty — the store still opens")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("orders.corrupted-") },
                "bytes are rescued to a sidecar, never destroyed")
    }

    @Test("claims-sync.json migrates into syncStates + pendingDiscoveries")
    func syncStateMigrates() throws {
        let json = """
            {"cursor": "eyJ-opaque", "historyBackfilled": true,
             "pendingClaimIDs": ["claim-a", "claim-b"]}
            """
        try write(Data(json.utf8), named: "claims-sync.json")
        let database = makeDatabase()

        let state = database.readSyncState()
        #expect(state.cursor == "eyJ-opaque")
        #expect(!state.historyBackfilled,
                "the file has no account identity — a foreign flag must not suppress this account's backfill; one rescan is the price")
        #expect(state.pendingClaimIDs == ["claim-a", "claim-b"])
    }

    @Test("places.json migrates into savedPlaces")
    func placesMigrate() throws {
        let place = SavedPlace(
            name: "Склад", kind: .warehouse,
            point: RoutePoint(latitude: 59, longitude: 30, address: "Невский, 100",
                              contactName: "Иван", contactPhone: "+7912"))
        let encoder = JSONEncoder()
        try write(encoder.encode([place]), named: "places.json")
        let database = makeDatabase()

        let stored = try #require(database.readPlaces().first)
        #expect(stored.name == "Склад")
        #expect(stored.kind == .warehouse)
        #expect(stored.point.contactName == "Иван")
        #expect(stored.point.contactPhone == "+7912")
    }

    // MARK: Custom fields — the «Ваши поля» schema and its values

    @Test("Field definitions round-trip in schema order")
    func fieldDefinitionsRoundTrip() throws {
        let database = makeDatabase()
        let a = CustomFieldDefinition(
            name: "Заказ", isOptional: false, carrier: .orderNumber, position: 0)
        let b = CustomFieldDefinition(
            name: "Тип груза", kind: .choice, choices: ["Документы", "Коробка"],
            position: 1)

        try database.saveFieldDefinition(a)
        try database.saveFieldDefinition(b)

        let stored = try database.fieldDefinitions()
        #expect(stored.map(\.name) == ["Заказ", "Тип груза"])
        #expect(stored[0].isShownByDefault,
                "required ⇒ shown by default — the store normalizes the trap")
        #expect(stored[1].choices == ["Документы", "Коробка"])
    }

    @Test("One claimant per carrier slot")
    func carrierSlotIsExclusive() throws {
        let database = makeDatabase()
        try database.saveFieldDefinition(
            CustomFieldDefinition(name: "Заказ", carrier: .orderNumber, position: 0))

        #expect(throws: AppDatabase.WriteError.fieldCarrierTaken) {
            try database.saveFieldDefinition(
                CustomFieldDefinition(name: "Номер", carrier: .orderNumber, position: 1))
        }
        // Re-saving the claimant itself is fine — only a *second* claim refuses.
        try database.saveFieldDefinition(
            CustomFieldDefinition(
                id: try #require(database.fieldDefinitions().first).id,
                name: "Заказ", carrier: .orderNumber, position: 0))
    }

    @Test("Field values record with the order, survive later updates, and replace")
    func fieldValueLifecycle() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-f")
        let def = CustomFieldDefinition(name: "Заказ", position: 0)
        try database.saveFieldDefinition(def)
        let fields = [OrderCustomField(
            orderID: order.id, fieldRef: def.id, name: "Заказ", value: "4417")]

        try database.recordOrder(order, customFields: fields)
        #expect(try database.orderCustomFields(orderID: order.id).map(\.value) == ["4417"])
        #expect(try database.allOrderCustomFields().count == 1)

        // A status update passing nothing leaves the values alone — a cancel must
        // never erase «Заказ 4417» off the record.
        var updated = order
        updated.status = .cancelled
        try database.recordOrder(updated)
        #expect(try database.orderCustomFields(orderID: order.id).map(\.value) == ["4417"])

        // An explicit set replaces wholesale — the draft owns all of them.
        try database.recordOrder(updated, customFields: [
            OrderCustomField(orderID: order.id, fieldRef: def.id, name: "Заказ", value: "4418"),
        ])
        let stored = try database.orderCustomFields(orderID: order.id)
        #expect(stored.map(\.value) == ["4418"])
        #expect(stored.first?.id == fields.first?.id,
                "the id derives from order‖field — an edit updates in place")
    }

    @Test("A value outlives its definition — the name snapshot renders it")
    func orphanedValueKeepsItsName() throws {
        let database = makeDatabase()
        let def = CustomFieldDefinition(name: "Накладная", position: 0)
        try database.saveFieldDefinition(def)
        let order = Order(
            created: .now, status: .done,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")])
        try database.recordOrder(order, customFields: [
            OrderCustomField(orderID: order.id, fieldRef: def.id,
                             name: "Накладная", value: "77"),
        ])

        try database.deleteFieldDefinition(id: def.id)

        let stored = try #require(database.orderCustomFields(orderID: order.id).first)
        #expect(stored.name == "Накладная")
        #expect(stored.value == "77")
    }

    // MARK: Provider events — the owner-written feed

    @Test("An event records once — its replay is news to nobody")
    func providerEventDeduplicates() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-e")
        try database.recordOrder(order)
        let event = ProviderEvent(
            orderID: order.id, providerEventID: 7, at: .now,
            kind: "status", providerStatus: "performer_found", source: "journal")

        #expect(try database.recordProviderEvent(event).inserted)
        #expect(try !database.recordProviderEvent(event).inserted,
                "a replayed feed id merges by key — the notification layer reads false as silence")
        #expect(try database.providerEvents(orderID: order.id).count == 1)
    }

    /// The notification layer's question, answered by the database: did this
    /// event move the order to a provider word the sender hasn't been told?
    /// A replay didn't, a stale event didn't, and a re-sighting of the same
    /// word didn't — only a fresh observation of a different word did.
    @Test("statusAdvanced is the transition signal — replays and re-sightings don't fire it")
    func statusAdvancedMarksRealTransitions() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-t")
        try database.recordOrder(order)

        let found = ProviderEvent(
            orderID: order.id, providerEventID: 1,
            at: Date(timeIntervalSince1970: 1000),
            kind: "status", providerStatus: "performer_found", source: "journal")
        #expect(try database.recordProviderEvent(found) ==
                ProviderEventOutcome(inserted: true, statusAdvanced: true),
                "a new status word advances the mirror")
        #expect(try database.recordProviderEvent(found) ==
                ProviderEventOutcome(inserted: false, statusAdvanced: false),
                "the replay inserts nothing and announces nothing")

        // The same word sighted through a different feed is a *new timeline
        // row* — dedupe is per (status, source) — but not a new status:
        // «courier found» must not banner twice because search saw it too.
        #expect(try database.recordProviderEvent(ProviderEvent(
            orderID: order.id,
            at: Date(timeIntervalSince1970: 1200),
            kind: "sighting", providerStatus: "performer_found", source: "search")) ==
                ProviderEventOutcome(inserted: true, statusAdvanced: false),
                "the same word from another feed lands on the timeline silently")

        // A stale event is history — it inserts, it does not announce.
        #expect(try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 0,
            at: Date(timeIntervalSince1970: 500),
            kind: "status", providerStatus: "accepted", source: "journal")) ==
                ProviderEventOutcome(inserted: true, statusAdvanced: false),
                "an event older than the mirror's observation is timeline-only")

        // And a genuinely new word through the sighting path fires — the
        // journal's gap is exactly what sightings backstop.
        #expect(try database.recordProviderEvent(ProviderEvent(
            orderID: order.id,
            at: Date(timeIntervalSince1970: 1400),
            kind: "sighting", providerStatus: "delivery_arrived", source: "card")) ==
                ProviderEventOutcome(inserted: true, statusAdvanced: true))
    }

    @Test("A status event writes the mirror — but an older event can't rewind it")
    func providerEventUpdatesMirror() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-m")
        try database.recordOrder(order)

        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 3,
            at: Date(timeIntervalSince1970: 1000),
            kind: "status", providerStatus: "delivery_arrived", source: "journal"))
        // A late-arriving journal entry with an older stamp is *new* to the
        // timeline — dedupe is per-key — but the mirror only moves forward: the
        // order was already sighted at 1000, so 900 must not regress it
        // (review, PR #6).
        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 2,
            at: Date(timeIntervalSince1970: 900),
            kind: "status", providerStatus: "pickuped", source: "journal"))
        #expect(try database.providerEvents(orderID: order.id).map(\.providerStatus)
                == ["pickuped", "delivery_arrived"],
                "events read oldest-first by stamp, not by arrival")

        let mirror: Row? = try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT "providerStatus", "providerObservedAt"
                FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        let status: String? = mirror?["providerStatus"]
        let observedAt: Double? = mirror?["providerObservedAt"]
        #expect(status == "delivery_arrived",
                "the newer observation owns the mirror, not the last-arriving event")
        #expect(observedAt == 1000)
    }

    /// A sighting has no feed id — the same status seen again derives the same
    /// row and dedupes out of the timeline. But the mirror must still move: the
    /// repeat *is* fresh information ("still this status, as of now") and its
    /// detail may have changed (review, PR #6).
    @Test("A repeated sighting refreshes the mirror without a second timeline row")
    func repeatedSightingRefreshesMirror() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-s")
        try database.recordOrder(order)

        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, at: Date(timeIntervalSince1970: 1000),
            kind: "status", providerStatus: "delivery_arrived",
            detail: "courier waiting", source: "card"))
        #expect(try !database.recordProviderEvent(ProviderEvent(
            orderID: order.id, at: Date(timeIntervalSince1970: 1300),
            kind: "status", providerStatus: "delivery_arrived",
            detail: "courier called", source: "card")).inserted,
                "same status from the same source is the same sighting — no second row")
        #expect(try database.providerEvents(orderID: order.id).count == 1)

        let mirror: Row? = try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT "providerDetail", "providerObservedAt"
                FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        let detail: String? = mirror?["providerDetail"]
        let observedAt: Double? = mirror?["providerObservedAt"]
        #expect(detail == "courier called")
        #expect(observedAt == 1300)
    }

    /// A non-status event carries its own detail — «850 RUB» is about the price,
    /// not about the status. Writing it beside the stored status would pair the
    /// old observation with an unrelated payload (review, PR #6).
    @Test("A detail without a status never poses as the status's own")
    func nonStatusEventLeavesTheMirrorAlone() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-p")
        try database.recordOrder(order)

        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 1,
            at: Date(timeIntervalSince1970: 1000),
            kind: "status", providerStatus: "pickuped",
            detail: "courier collected parcel", source: "journal"))
        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 2,
            at: Date(timeIntervalSince1970: 1100),
            kind: "price", detail: "850 RUB", source: "journal"))

        let mirror: Row? = try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT "providerStatus", "providerDetail"
                FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        let status: String? = mirror?["providerStatus"]
        let detail: String? = mirror?["providerDetail"]
        #expect(status == "pickuped")
        #expect(detail == "courier collected parcel",
                "the price event's detail is not the status's detail")
        // …while the timeline keeps it — the feed lost nothing.
        #expect(try database.providerEvents(orderID: order.id).map(\.kind)
                == ["status", "price"])
    }

    @Test("An event bumps the order's activity without ever rewinding it")
    func providerEventMovesActivityForwardOnly() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-a")
        try database.recordOrder(order)
        // record() itself stamps "now" — the events must sit either side of it.
        let later = Date.now.addingTimeInterval(60)
        let earlier = Date.now.addingTimeInterval(-3600)

        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 1,
            at: later, kind: "status", source: "journal"))
        try database.recordProviderEvent(ProviderEvent(
            orderID: order.id, providerEventID: 2,
            at: earlier, kind: "status", source: "journal"))

        let activity: Double = try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT "lastActivityAt" FROM "orders" WHERE "id" = ?
                """, arguments: AppDatabase.args([order.id]))?["lastActivityAt"] ?? 0
        }
        #expect(activity == later.timeIntervalSince1970,
                "the older event is history, not the newest activity")
    }
}

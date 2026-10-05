import CloudKit
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

    @Test("A directory that does not exist yet is created, not reported")
    func opensInAnAbsentDirectory() throws {
        let nested = directory.appendingPathComponent("not/yet/here", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        let database = AppDatabase(
            directory: nested, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test")
        #expect(try database.readOrders().isEmpty, "a fresh store reads empty — never SQLite error 14")
        #expect(FileManager.default.fileExists(atPath: nested.path))
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
        // Issued profiles encode "all iCloud services" as the wildcard string,
        // not an array — both development and distribution profiles.
        #expect(AppDatabase.profileAllowsCloudKit(["Entitlements": [
            "com.apple.developer.icloud-services": "*",
            "com.apple.developer.icloud-container-identifiers": [container],
        ]], containerIdentifier: container), "the wildcard grant must pass the gate")
        #expect(!AppDatabase.profileAllowsCloudKit(
            ["Entitlements": [:]], containerIdentifier: container),
                "a profile without iCloud must fail the gate")
        #expect(!AppDatabase.profileAllowsCloudKit(["Entitlements": [
            "com.apple.developer.icloud-services": ["CloudDocuments"],
            "com.apple.developer.icloud-container-identifiers": [container],
        ]], containerIdentifier: container), "CloudDocuments alone must fail the gate")
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
        point.addressParts = AddressParts(building: "3", entrance: "2", apartment: "12")
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
        #expect(stored.route[0].addressParts?.building == "3",
                "the wire's `building` slot parks on the same row (YD-10)")
        #expect(stored.route[0].contactPhone == "+79123456789")
        #expect(stored.route[1].address == "Невский, 100")
    }

    /// YD-15's discharge: the role rides the point now — a return leg persists
    /// as `"return"` in `routeStops` instead of flattening to `dropoff`.
    @Test("A carried stop role round-trips — the return leg keeps its name")
    func stopRolesRoundTrip() throws {
        let database = makeDatabase()
        var pickup = RoutePoint(latitude: 55, longitude: 37, address: "Склад")
        pickup.role = .pickup
        var dropoff = RoutePoint(latitude: 56, longitude: 38, address: "Тверская, 6")
        dropoff.role = .dropoff
        var returnLeg = RoutePoint(latitude: 55, longitude: 37, address: "Склад")
        returnLeg.role = .return
        let order = Order(created: .now, status: .done,
                          route: [pickup, dropoff, returnLeg], claimID: "claim-77")

        try database.recordOrder(order)
        let stored = try #require(database.readOrders().first)

        #expect(stored.route.map(\.role) == [.pickup, .dropoff, .return])
        let spellings = try database.queue.read {
            try String.fetchAll($0, sql: """
                SELECT "role" FROM "routeStops" ORDER BY "position"
                """)
        }
        #expect(spellings == ["pickup", "dropoff", "return"])
    }

    /// Rows written before roles existed keep their honesty: the write side
    /// fills what position would say (first `pickup`, rest `dropoff`), and an
    /// unrecognised spelling reads back as roleless rather than dropping the
    /// stop — `RouteLine` then derives the mark by position, the old contract.
    @Test("A roleless write fills positionally; an unknown spelling reads roleless")
    func rolelessAndUnknownSpellings() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .done,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А"),
                    RoutePoint(latitude: 56, longitude: 38, address: "Б")],
            claimID: "claim-78")

        try database.recordOrder(order)
        let stored = try #require(database.readOrders().first)
        #expect(stored.route.map(\.role) == [.pickup, .dropoff],
                "position fills a roleless write — the pre-role contract")

        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO "routeStops"
                  ("id", "orderID", "position", "role", "latitude", "longitude",
                   "address")
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    UUID().uuidString.lowercased(),
                    order.id.uuidString.lowercased(), 2, "teleport",
                    59.0, 30.0, "В"])
        }
        let reread = try #require(database.readOrders().first)
        #expect(reread.route.count == 3)
        #expect(reread.route[2].role == nil)
        #expect(RouteLine.stops(from: reread.route).map(\.role)
                == [.start, .stop(number: 2), .end],
                "position derives the mark a strange spelling cannot")
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

    // MARK: Synced writes — upsert and prune, never delete-then-reinsert (YD-34)

    /// The sync metadata rows for one table, keyed by `recordPrimaryKey`:
    /// `_isDeleted` is the tombstone, `userModificationTime` is what an upload
    /// queue reads — a write that moves neither is a write CloudKit never sees.
    private func syncedMetadata(
        _ database: AppDatabase, type: String
    ) throws -> [String: (deleted: Bool, modified: Int64)] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT "recordPrimaryKey", "_isDeleted", "userModificationTime"
                FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata"
                WHERE "recordType" = ?
                """, arguments: [type])
        }.reduce(into: [:]) { map, row in
            map[row["recordPrimaryKey"] as String] =
                (deleted: row["_isDeleted"], modified: row["userModificationTime"])
        }
    }

    @Test("A re-record keeps the stops' records alive — upsert, never tombstone")
    func rerecordKeepsStopRecordsAlive() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let order = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А"),
                    RoutePoint(latitude: 56, longitude: 38, address: "Б")],
            claimID: "claim-1")
        let fields = [OrderCustomField(
            orderID: order.id, fieldRef: UUID(), name: "Подъезд", value: "3")]
        try database.recordOrder(order, customFields: fields)
        let stopsBefore = try syncedMetadata(database, type: "routeStops")
        let fieldsBefore = try syncedMetadata(database, type: "orderCustomFields")
        #expect(stopsBefore.count == 2)
        #expect(fieldsBefore.count == 1)

        var edited = order
        edited.route[0].address = "А, корп. 2"
        var editedFields = fields
        editedFields[0].value = "5"
        try database.recordOrder(edited, customFields: editedFields)

        let stopsAfter = try syncedMetadata(database, type: "routeStops")
        let fieldsAfter = try syncedMetadata(database, type: "orderCustomFields")
        #expect(stopsAfter.count == 2, "re-derived stop ids upsert in place")
        for (key, before) in stopsBefore {
            let after = try #require(stopsAfter[key])
            #expect(after.deleted == false,
                    "delete-then-reinsert would leave a tombstone — the remote record dies")
            #expect(after.modified > before.modified,
                    "the upsert re-queues the row; INSERT OR REPLACE never would")
        }
        for (key, before) in fieldsBefore {
            let after = try #require(fieldsAfter[key])
            #expect(after.deleted == false)
            #expect(after.modified > before.modified)
        }
        #expect(try database.readOrders().first?.route.count == 2)
    }

    @Test("A shrunk route tombstones only the dropped stop")
    func shrinkingRouteTombstonesOnlyTheDroppedStop() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let order = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А"),
                    RoutePoint(latitude: 56, longitude: 38, address: "Б"),
                    RoutePoint(latitude: 57, longitude: 39, address: "В")],
            claimID: "claim-1")
        try database.recordOrder(order)

        var shortened = order
        shortened.route = Array(order.route.prefix(2))
        try database.recordOrder(shortened)

        let metadata = try syncedMetadata(database, type: "routeStops")
        #expect(metadata.count == 3, "the dropped row's metadata stays as a tombstone")
        #expect(metadata.values.filter(\.deleted).count == 1,
                "the third stop — and only it — queues its remote delete")
        #expect(metadata.values.filter { !$0.deleted }.count == 2)
        #expect(try database.readOrders().first?.route.count == 2)
    }

    @Test("A renamed place re-queues its record")
    func renamedPlaceUploads() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let place = SavedPlace(
            name: "Дом", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6"))
        try database.savePlace(place)
        let before = try #require(
            syncedMetadata(database, type: "savedPlaces").values.first)

        var renamed = place
        renamed.name = "Дом (черный вход)"
        try database.savePlace(renamed)

        let after = try #require(
            syncedMetadata(database, type: "savedPlaces").values.first)
        #expect(after.deleted == false)
        #expect(after.modified > before.modified,
                "INSERT OR REPLACE never bumps the stamp — the edit would stay local")
    }

    @Test("A re-saved template keeps its items' records; a removed item tombstones")
    func resavedTemplateKeepsItemRecords() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        var template = ParcelTemplate(name: "Коробка", items: [
            .init(name: "А", currency: "RUB"),
            .init(name: "Б", currency: "RUB"),
        ])
        try database.saveParcelTemplate(template)
        let before = try syncedMetadata(database, type: "parcelTemplateItems")
        #expect(before.count == 2)

        template.items[1].name = "Б новая"
        try database.saveParcelTemplate(template)
        var after = try syncedMetadata(database, type: "parcelTemplateItems")
        #expect(after.count == 2)
        for (key, old) in before {
            let now = try #require(after[key])
            #expect(now.deleted == false)
            #expect(now.modified > old.modified,
                    "an edited item re-queues; delete-then-reinsert would tombstone it")
        }

        template.items = [template.items[0]]
        try database.saveParcelTemplate(template)
        after = try syncedMetadata(database, type: "parcelTemplateItems")
        #expect(after.count == 2)
        #expect(after.values.filter(\.deleted).count == 1,
                "the removed item is a true delete — it tombstones")
        #expect(after.values.filter { !$0.deleted }.count == 1)
        #expect(try database.readParcelTemplates().first?.items.count == 1)
    }

    /// A cleared field is not a delete — the row stays with `value = ''`, so a
    /// refill under the same derived id never reuses a tombstoned key (YD-34).
    /// Only dropping the field from the passed set prunes.
    @Test("A cleared field keeps its row — refilling it never reuses a tombstone")
    func clearedFieldKeepsItsRow() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let order = Order(
            created: .now, status: .searching,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-1")
        let fields = [OrderCustomField(
            orderID: order.id, fieldRef: UUID(), name: "Подъезд", value: "3")]
        try database.recordOrder(order, customFields: fields)
        #expect(try database.orderCustomFields(orderID: order.id).count == 1)

        var cleared = fields
        cleared[0].value = ""
        try database.recordOrder(order, customFields: cleared)
        #expect(try syncedMetadata(database, type: "orderCustomFields")
            .values.allSatisfy { !$0.deleted },
                "a cleared field keeps its row — a delete would tombstone the id")
        #expect(try database.orderCustomFields(orderID: order.id).isEmpty,
                "the empty value reads as absent")
        #expect(try database.allOrderCustomFields().isEmpty)

        var refilled = fields
        refilled[0].value = "5"
        try database.recordOrder(order, customFields: refilled)
        #expect(try syncedMetadata(database, type: "orderCustomFields")
            .values.allSatisfy { !$0.deleted })
        #expect(try database.orderCustomFields(orderID: order.id).first?.value == "5")
    }

    /// A template's item id is its own — an item copied into another template
    /// writes under a derived id rather than re-homing the row (YD-34), and a
    /// re-save of the same stale model re-derives that id — an upsert, never a
    /// prune-and-remint that would tombstone the copy.
    @Test("A copied item keeps its own template — the id is never re-homed")
    func copiedItemKeepsItsTemplate() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let copiedID = UUID()
        let a = ParcelTemplate(name: "А", items: [
            .init(id: copiedID, name: "Книга", currency: "RUB"),
        ])
        try database.saveParcelTemplate(a)

        let b = ParcelTemplate(name: "Б", items: [
            .init(id: copiedID, name: "Книга", currency: "RUB"),
        ])
        try database.saveParcelTemplate(b)

        let read = try database.readParcelTemplates()
        let storedA = try #require(read.first { $0.id == a.id })
        let storedB = try #require(read.first { $0.id == b.id })
        #expect(storedA.items.map(\.id) == [copiedID], "template A keeps its item")
        let bItemID = try #require(storedB.items.first?.id)
        #expect(storedB.items.count == 1)
        #expect(bItemID != copiedID, "the copy writes under a fresh id")

        // Re-saving the same stale model re-derives the copy's row id — one row,
        // still alive; a random id would prune-then-remint each save.
        try database.saveParcelTemplate(b)
        let metadata = try syncedMetadata(database, type: "parcelTemplateItems")
        let copyMeta = try #require(metadata[bItemID.uuidString.lowercased()])
        #expect(copyMeta.deleted == false,
                "the derived id re-lands in place — no tombstone churn")
        let reread = try database.readParcelTemplates()
        #expect(reread.first { $0.id == b.id }?.items.map(\.id) == [bItemID])
        #expect(reread.first { $0.id == a.id }?.items.map(\.id) == [copiedID])

        // The read returns the stored id, so saving what was read is stable too.
        try database.saveParcelTemplate(storedB)
        let rereadAgain = try database.readParcelTemplates()
        #expect(rereadAgain.first { $0.id == b.id }?.items.map(\.id) == [bItemID])
        #expect(rereadAgain.first { $0.id == a.id }?.items.map(\.id) == [copiedID])
    }

    /// Two copies of the same foreign item in one template are two rows — the
    /// occurrence counter keeps their ids distinct, and entry order re-lands
    /// the same identities on a re-save.
    @Test("Two copies of one item stay two rows — repeated copies keep distinct identities")
    func repeatedCopiesKeepDistinctIdentities() throws {
        let database = makeDatabase()
        let copiedID = UUID()
        let a = ParcelTemplate(name: "А", items: [
            .init(id: copiedID, name: "Книга", currency: "RUB"),
        ])
        try database.saveParcelTemplate(a)

        let b = ParcelTemplate(name: "Б", items: [
            .init(id: copiedID, name: "Книга", quantity: 1, currency: "RUB"),
            .init(id: copiedID, name: "Книга", quantity: 3, currency: "RUB"),
        ])
        try database.saveParcelTemplate(b)

        var storedB = try #require(database.readParcelTemplates().first { $0.id == b.id })
        #expect(storedB.items.count == 2, "the copies must not collapse into one row")
        #expect(storedB.items.map(\.quantity) == [1, 3])
        let ids = storedB.items.map(\.id)
        #expect(Set(ids).count == 2)

        // Re-saving the same stale model re-derives both ids — same two rows.
        try database.saveParcelTemplate(b)
        storedB = try #require(database.readParcelTemplates().first { $0.id == b.id })
        #expect(storedB.items.map(\.id) == ids)
        #expect(storedB.items.map(\.quantity) == [1, 3])
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
    @Test("A stale merge rewinds nothing — not the stamp, not the fields it carries")
    func staleMergeCannotRewindObservedAt() throws {
        let database = makeDatabase()
        var order = Order(created: .now, status: .active, route: [], claimID: "claim-8")
        order.price = "950.00"
        let fresh = Date.now
        let stale = fresh.addingTimeInterval(-600)

        try database.recordOrder(order, providerObservedAt: fresh)
        var refetched = order
        refetched.price = "910.00"
        try database.recordOrder(refetched, providerObservedAt: stale)

        let mirror = try database.queue.read {
            try Row.fetchOne($0, sql: """
                SELECT "providerObservedAt", "price" FROM "orderProviderStates"
                WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        #expect(mirror?["providerObservedAt"] == fresh.timeIntervalSince1970,
                "the fresher stamp holds — a stale answer describes older provider truth")
        let price: String? = mirror?["price"]
        #expect(price == "950.00",
                "the stale answer's fields were never written beside the fresh stamp")
    }

    /// The widget surface's data (board `5a`/`5b`): courier, vehicle, the raw ETA
    /// minutes and their as-of stamp all round-trip through the mirror, and the
    /// arrival moment derives from *provider* time — never the read's.
    @Test("Courier, ETA, and the observation stamp round-trip through the mirror")
    func courierFieldsRoundTrip() throws {
        let database = makeDatabase()
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-eta",
            courierName: "Сергей", courierVehicle: "м 234 ор 77", etaMinutes: 14,
            providerStatus: "pickuped")

        try database.recordOrder(order, providerObservedAt: observed)
        let stored = try #require(database.readOrders().first)

        #expect(stored.courierName == "Сергей")
        #expect(stored.courierVehicle == "м 234 ор 77")
        #expect(stored.etaMinutes == 14)
        #expect(stored.providerStatus == "pickuped",
                "the wire's own phase word rides the flat order — «у двери» ≠ «едет»")
        #expect(stored.providerObservedAt == observed)
        #expect(stored.etaAt == observed.addingTimeInterval(14 * 60),
                "the arrival moment is the provider's clock plus its own estimate")
    }

    /// The mirror is the latest sighting's projection: a fresher sighting that
    /// reports no courier must erase the name a previous one left — displaying a
    /// courier who is no longer assigned is worse than displaying none.
    @Test("A sighting without a courier clears the stale name")
    func sightingWithoutCourierClearsIt() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-courier",
            courierName: "Сергей", etaMinutes: 14)
        let fresh = Date.now

        try database.recordOrder(order, providerObservedAt: fresh)
        var reassigned = order
        reassigned.courierName = nil
        reassigned.courierVehicle = nil
        reassigned.etaMinutes = nil
        try database.recordOrder(reassigned,
                                 providerObservedAt: fresh.addingTimeInterval(60))

        let stored = try #require(database.readOrders().first)
        #expect(stored.courierName == nil)
        #expect(stored.etaMinutes == nil)
    }

    /// The regression the reviewer caught (Kit PR #8): an unstamped write is a
    /// *local* edit — an in-memory `Order` from before the last sighting still
    /// carries that sighting's courier/ETA/provider word. Rewriting the mirror
    /// with them would regress what the provider reported while keeping its
    /// fresh stamp — a courier swap displayed as the latest truth.
    @Test("A local edit cannot rewind a fresher sighting's courier fields")
    func unstampedWritePreservesCourierMirror() throws {
        let database = makeDatabase()
        let observed = Date.now
        var order = Order(created: .now, status: .active, route: [], claimID: "c-guard")
        try database.recordOrder(order)
        // The sighting: courier assigned, ETA and wire word land together.
        order.courierName = "Сергей"
        order.courierVehicle = "м 234 ор 77"
        order.etaMinutes = 14
        order.providerStatus = "pickuped"
        try database.recordOrder(order, providerObservedAt: observed)

        // The local edit: the same in-memory copy minus what the sighting
        // taught it — a route change must not drag the mirror backwards.
        var staleLocal = order
        staleLocal.courierName = nil
        staleLocal.courierVehicle = nil
        staleLocal.etaMinutes = nil
        staleLocal.providerStatus = "performer_lookup"
        staleLocal.route = [RoutePoint(latitude: 55, longitude: 37, address: "Б")]
        try database.recordOrder(staleLocal)

        let stored = try #require(database.readOrders().first)
        #expect(stored.courierName == "Сергей",
                "the fresher sighting's courier survives a local edit")
        #expect(stored.courierVehicle == "м 234 ор 77")
        #expect(stored.etaMinutes == 14)
        #expect(stored.providerStatus == "pickuped",
                "the wire word is provider-owned too — a local write can't rewind it")
        #expect(stored.route.first?.address == "Б",
                "and the local edit itself — the sender's field — applied")
    }

    /// The callout's mini-timeline data (board `4a`): each stop's provider
    /// visit — status, the handover's actual stamp, the estimate while it
    /// waits — round-trips per point, and a sender-authored point reads none.
    @Test("Per-stop visit state round-trips through routeStops")
    func visitStateRoundTrips() throws {
        let database = makeDatabase()
        let visitedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let expectedAt = Date(timeIntervalSince1970: 1_700_005_000)
        let order = Order(
            created: .now, status: .active,
            route: [
                RoutePoint(latitude: 55, longitude: 37, address: "Забор",
                           visit: .init(status: .visited, visitedAt: visitedAt)),
                RoutePoint(latitude: 55.1, longitude: 37.1, address: "Доставка",
                           visit: .init(status: .pending, expectedAt: expectedAt)),
                RoutePoint(latitude: 55.2, longitude: 37.2, address: "Черновик"),
            ],
            claimID: "claim-visits")

        try database.recordOrder(order, providerObservedAt: .now)
        let stored = try #require(database.readOrders().first)

        #expect(stored.route[0].visit?.status == .visited)
        #expect(stored.route[0].visit?.visitedAt == visitedAt)
        #expect(stored.route[1].visit?.status == .pending)
        #expect(stored.route[1].visit?.expectedAt == expectedAt)
        #expect(stored.route[2].visit == nil,
                "a point the provider never reported on carries no visit box")
    }

    /// The visit columns land on databases born before them: guarded ALTERs,
    /// existing stop rows intact, the new fields reading absent.
    @Test("A pre-visit routeStops table gains the columns, stops intact")
    func visitColumnsMigrate() throws {
        let raw = try DatabaseQueue(
            path: directory.appendingPathComponent(AppDatabase.filename).path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE "orders" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "createdAt" REAL NOT NULL,
                  "providerAccountRef" TEXT,
                  "provider" TEXT NOT NULL,
                  "lastActivityAt" REAL NOT NULL
                ) STRICT;
                CREATE TABLE "routeStops" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "orderID" TEXT NOT NULL
                    REFERENCES "orders"("id") ON DELETE CASCADE,
                  "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
                  "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
                  "address" TEXT NOT NULL,
                  "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
                  "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
                  "contactPhone" TEXT, "contactPhoneExtension" TEXT
                ) STRICT;
                INSERT INTO "orders"
                  ("id", "createdAt", "provider", "lastActivityAt")
                VALUES ('00000000-0000-0000-0000-000000000001',
                        1700000000, 'test', 1700000000);
                INSERT INTO "routeStops"
                  ("id", "orderID", "position", "role",
                   "latitude", "longitude", "address")
                VALUES ('00000000-0000-0000-0000-000000000002',
                        '00000000-0000-0000-0000-000000000001',
                        0, 'pickup', 55, 37, 'Москворечье, 6');
                """)
        }

        let database = makeDatabase()
        let columns = try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM pragma_table_info('routeStops')
                """)
        }
        #expect(columns.contains("visitStatus")
                && columns.contains("visitedAt")
                && columns.contains("expectedVisitAt"),
                "the three visit columns all arrived")
        #expect(columns.contains("building"),
                "the door-details set grew the корпус column (YD-10)")

        let stored = try #require(database.readOrders().first)
        #expect(stored.route.first?.address == "Москворечье, 6",
                "the pre-existing stop survived the ALTER")
        #expect(stored.route.first?.visit == nil,
                "a row written before visits reads them absent")
    }

    /// The visit columns obey the same rule as the courier mirror one level up
    /// (review, PR #10): an unstamped write is a *local* edit, and an in-memory
    /// copy from before the last sighting — or one whose points carry a stale
    /// visit — must not erase what the provider recorded at the door.
    @Test("A local edit cannot erase a sighting's visit records")
    func unstampedWritePreservesVisitMirror() throws {
        let database = makeDatabase()
        let visitedAt = Date(timeIntervalSince1970: 1_700_001_000)
        var order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "Забор")],
            claimID: "c-visits")
        try database.recordOrder(order)

        // The sighting: the courier arrived at the pickup door.
        order.route[0].visit = .init(status: .visited, visitedAt: visitedAt)
        try database.recordOrder(order, providerObservedAt: .now)

        // The local edit: an in-memory copy that never learned of the visit —
        // and even one carrying a *stale* visit — cannot regress the record.
        var staleLocal = order
        staleLocal.route[0].visit = .init(status: .pending)
        staleLocal.route[0].contactPhone = "+7 900 000-00-00"
        try database.recordOrder(staleLocal)

        let stored = try #require(database.readOrders().first)
        #expect(stored.route[0].visit?.status == .visited,
                "the stored record wins over a stale local copy")
        #expect(stored.route[0].visit?.visitedAt == visitedAt)
        #expect(stored.route[0].contactPhone == "+7 900 000-00-00",
                "while the sender's own edit still applied")

        // And a point with no visit supplied re-adopts the stored record too.
        var bareLocal = order
        bareLocal.route[0].visit = nil
        try database.recordOrder(bareLocal)
        #expect(try database.readOrders().first?.route[0].visit?.status == .visited)
    }

    /// Stops match by destination, not position: a local write that reorders
    /// the route keeps each visit attached to its own stop (review, PR #10).
    @Test("A reordered route keeps each stop's visit record")
    func reorderKeepsVisitAttribution() throws {
        let database = makeDatabase()
        let visitedAt = Date(timeIntervalSince1970: 1_700_001_000)
        var order = Order(
            created: .now, status: .active,
            route: [
                RoutePoint(latitude: 55, longitude: 37, address: "Первый"),
                RoutePoint(latitude: 55.1, longitude: 37.1, address: "Второй"),
            ],
            claimID: "c-reorder")
        order.route[0].visit = .init(status: .visited, visitedAt: visitedAt)
        order.route[1].visit = .init(status: .pending)
        try database.recordOrder(order, providerObservedAt: .now)

        // A local write replays the same destinations swapped — the visit
        // follows its stop, not its slot.
        var reordered = order
        reordered.route = [order.route[1], order.route[0]]
        reordered.route[0].visit = nil
        reordered.route[1].visit = nil
        try database.recordOrder(reordered)

        let stored = try #require(database.readOrders().first)
        #expect(stored.route[0].address == "Второй")
        #expect(stored.route[0].visit?.status == .pending)
        #expect(stored.route[1].address == "Первый")
        #expect(stored.route[1].visit?.status == .visited)
        #expect(stored.route[1].visit?.visitedAt == visitedAt)
    }

    /// The strict half of the rule (review, PR #10): an unstamped write never
    /// *mints* a visit either — a route copied off a completed order must not
    /// arrive wearing the courier's account of a run that never happened.
    @Test("A local write cannot mint a visit record")
    func unstampedWriteNeverMintsVisits() throws {
        let database = makeDatabase()
        let visitedAt = Date(timeIntervalSince1970: 1_700_001_000)
        var order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "Забор")],
            claimID: "c-source")
        order.route[0].visit = .init(status: .visited, visitedAt: visitedAt)
        try database.recordOrder(order, providerObservedAt: .now)

        // A copy repeats the route — the destination changed, the visit stayed.
        var copy = order
        copy.id = UUID()
        copy.claimID = "c-repeat"
        copy.route[0].address = "Другой адрес"
        try database.recordOrder(copy)   // unstamped — a local write

        let stored = try #require(database.readOrders().first { $0.id == copy.id })
        #expect(stored.route[0].visit == nil,
                "the copied visit does not attach to a destination that never earned it")
    }

    /// The collaborator's read (Kit PR #8): the schema is private-tier, so the
    /// value row's own `carrier` snapshot is the only thing a shared order can
    /// answer from — no join, no definition.
    @Test("The order number resolves off the value's own carrier snapshot")
    func orderNumberNeedsNoDefinition() throws {
        let database = makeDatabase()
        let order = Order(created: .now, status: .active, route: [], claimID: "c-num")
        try database.recordOrder(order, customFields: [
            OrderCustomField(orderID: order.id, fieldRef: UUID(),
                             name: "Заказ", value: "4417", carrier: .orderNumber),
            OrderCustomField(orderID: order.id, fieldRef: UUID(),
                             name: "Тип груза", value: "Документы", carrier: .none),
        ])
        #expect(try database.orderNumber(for: order.id) == "4417")
    }

    /// Two carrier-conflicting values — history from before the slot was
    /// re-claimed — must still answer one winner, everywhere. The `fieldRef`
    /// fallback ordering is the stable one a collaborator can compute.
    @Test("Conflicting order-number values pick one deterministic winner")
    func orderNumberConflictIsDeterministic() throws {
        let database = makeDatabase()
        let order = Order(created: .now, status: .active, route: [], claimID: "c-num2")
        let firstRef = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let secondRef = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        try database.recordOrder(order, customFields: [
            OrderCustomField(orderID: order.id, fieldRef: secondRef,
                             name: "Номер", value: "B", carrier: .orderNumber),
            OrderCustomField(orderID: order.id, fieldRef: firstRef,
                             name: "Заказ", value: "A", carrier: .orderNumber),
        ])
        // No definitions: the fieldRef fallback sorts — 'A1' < 'B2' wins.
        #expect(try database.orderNumber(for: order.id) == "A")
    }

    /// The `carrier` backfill: a database whose values were written before the
    /// column existed still resolves its numbers — the ALTER fills them from
    /// the schema that typed them.
    @Test("The carrier column backfills pre-existing values from the schema")
    func carrierBackfillsOnMigration() throws {
        let orderID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let fieldRef = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
        // The store's TEXT id columns hold the lowercase form (`args` folds) —
        // a fixture row must spell them the same or the joins never meet.
        let raw = try DatabaseQueue(
            path: directory.appendingPathComponent(AppDatabase.filename).path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE "orders" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "createdAt" REAL NOT NULL,
                  "providerAccountRef" TEXT,
                  "provider" TEXT NOT NULL,
                  "lastActivityAt" REAL NOT NULL
                ) STRICT;
                CREATE TABLE "orderCustomFields" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "orderID" TEXT NOT NULL,
                  "fieldRef" TEXT NOT NULL, "name" TEXT NOT NULL, "value" TEXT NOT NULL
                ) STRICT;
                CREATE TABLE "customFieldDefinitions" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
                  "choicesJSON" TEXT NOT NULL,
                  "isOptional" INTEGER NOT NULL, "isShownByDefault" INTEGER NOT NULL,
                  "carrier" TEXT NOT NULL, "position" INTEGER NOT NULL
                ) STRICT;
                INSERT INTO "orders"
                  ("id", "createdAt", "provider", "lastActivityAt")
                VALUES ('\(orderID.uuidString.lowercased())',
                        1700000000, 'test', 1700000000);
                INSERT INTO "customFieldDefinitions"
                  ("id", "name", "kind", "choicesJSON",
                   "isOptional", "isShownByDefault", "carrier", "position")
                VALUES ('\(fieldRef.uuidString.lowercased())', 'Заказ', 'text',
                        '[]', 1, 1, 'orderNumber', 0);
                INSERT INTO "orderCustomFields"
                  ("id", "orderID", "fieldRef", "name", "value")
                VALUES ('00000000-0000-0000-0000-0000000000e1',
                        '\(orderID.uuidString.lowercased())',
                        '\(fieldRef.uuidString.lowercased())',
                        'Заказ', '4417');
                """)
        }

        let database = makeDatabase()
        #expect(try database.orderNumber(for: orderID) == "4417",
                "the pre-column value answers through its backfilled carrier")
    }

    /// The first column migration: a database born before the courier columns
    /// gets them via guarded `ALTER TABLE`, its rows survive, and reopening the
    /// same file is a no-op — the pragma check, not luck, makes it idempotent.
    @Test("A pre-migration database gains the courier columns, rows intact")
    func columnMigrationAddsToExistingDatabase() throws {
        // The file as it stood before the columns landed — old table shape,
        // one live row that must survive the ALTER.
        let raw = try DatabaseQueue(
            path: directory.appendingPathComponent(AppDatabase.filename).path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE "orders" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "createdAt" REAL NOT NULL,
                  "providerAccountRef" TEXT,
                  "provider" TEXT NOT NULL,
                  "lastActivityAt" REAL NOT NULL
                ) STRICT;
                CREATE TABLE "orderProviderStates" (
                  "orderID" TEXT PRIMARY KEY NOT NULL
                    REFERENCES "orders"("id") ON DELETE CASCADE,
                  "claimID" TEXT, "corpClientID" TEXT, "status" TEXT NOT NULL,
                  "providerStatus" TEXT, "providerDetail" TEXT,
                  "tariff" TEXT, "price" TEXT, "currency" TEXT,
                  "dueAt" REAL, "finishedAt" REAL,
                  "providerObservedAt" REAL, "mirroredAt" REAL NOT NULL
                ) STRICT;
                INSERT INTO "orders"
                  ("id", "createdAt", "provider", "lastActivityAt")
                VALUES ('00000000-0000-0000-0000-000000000001',
                        1700000000, 'test', 1700000000);
                INSERT INTO "orderProviderStates"
                  ("orderID", "status", "mirroredAt")
                VALUES ('00000000-0000-0000-0000-000000000001',
                        'active', 1700000000);
                """)
        }

        let database = makeDatabase()
        let columns = try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM pragma_table_info('orderProviderStates')
                """)
        }
        #expect(columns.contains("courierName")
                && columns.contains("courierVehicle")
                && columns.contains("etaMinutes"),
                "the three late columns all arrived")

        let stored = try database.readOrders()
        #expect(stored.count == 1, "the pre-existing row survived the ALTER")
        #expect(stored.first?.status == .active)

        // Reopening is a no-op — the pragma guard absorbs the repeat.
        _ = try makeDatabase().queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM pragma_table_info('orderProviderStates')
                """)
        }
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

    // MARK: The sender's library — templates and pins

    @Test("A template round-trips with its items in position order")
    func templateRoundTrips() throws {
        let database = makeDatabase()
        let template = ParcelTemplate(name: "Коробка учебников", pinned: true, items: [
            .init(name: "Учебники", quantity: 5, weightKg: 12, cost: "2500.00",
                  currency: "RUB", sizeLengthCm: 30, sizeWidthCm: 21, sizeHeightCm: 8),
            // The schema admits a bundle even though the v1 editor writes one —
            // position order is the contract this pins down.
            .init(name: "Тетради", quantity: 10, currency: "RUB"),
        ])

        try database.saveParcelTemplate(template)
        let stored = try #require(database.readParcelTemplates().first)

        #expect(stored.id == template.id)
        #expect(stored.name == "Коробка учебников")
        #expect(stored.pinned)
        #expect(stored.items.map(\.name) == ["Учебники", "Тетради"],
                "items ride back in position order")
        #expect(stored.items[0].cost == "2500.00")
        #expect(stored.items[0].sizeLengthCm == 30)
        #expect(stored.items[1].quantity == 10)
    }

    /// Children mirror the draft-save discipline: a template is a document, not
    /// a delta — a re-save with fewer items must not leave the old ones behind.
    @Test("A re-save rewrites a template's items wholesale")
    func templateSaveReplacesItems() throws {
        let database = makeDatabase()
        var template = ParcelTemplate(name: "Комплект", items: [
            .init(name: "А", currency: "RUB"),
            .init(name: "Б", currency: "RUB"),
        ])
        try database.saveParcelTemplate(template)

        template.items = [.init(name: "В", currency: "RUB")]
        template.name = "Комплект В"
        try database.saveParcelTemplate(template)

        let stored = try #require(database.readParcelTemplates().first)
        #expect(stored.name == "Комплект В")
        #expect(stored.items.map(\.name) == ["В"])
        let orphans = try database.queue.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM "parcelTemplateItems" WHERE "name" != 'В'
                """)!
        }
        #expect(orphans == 0, "removed items die with the rewrite — no strays")
    }

    @Test("Forgetting a template takes its items; forgetting twice succeeds")
    func deleteTemplateSweepsItems() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let template = ParcelTemplate(name: "Коробка", items: [
            .init(name: "А", currency: "RUB"),
        ])
        try database.saveParcelTemplate(template)

        try database.deleteParcelTemplate(id: template.id)
        #expect(try database.readParcelTemplates().isEmpty)
        let leftItems = try database.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \"parcelTemplateItems\"")!
        }
        #expect(leftItems == 0,
                "children die explicitly — the pragma is off, CASCADE never fires")

        // The tombstone is the sync contract: a deleted synced row marks its
        // metadata `_isDeleted` so the removal uploads — child rows included.
        let tombstones = try database.queue.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM "sqlitedata_icloud"."sqlitedata_icloud_metadata"
                WHERE "_isDeleted" = 1
                """)!
        }
        #expect(tombstones == 2, "root and item each leave a deletion tombstone")

        try database.deleteParcelTemplate(id: template.id)
        try database.deleteParcelTemplate(id: UUID())
    }

    /// The pin is curation, not content: it leads both pickers, and re-saving a
    /// remembered door under another name keeps the memory's pin — an adopt is
    /// not an unpin.
    @Test("Pinned entries lead both lists; adoption keeps the pin")
    func pinnedLeadsAndSurvivesAdoption() throws {
        let database = makeDatabase()
        let first = SavedPlace(
            name: "Дом", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6"))
        let second = SavedPlace(
            name: "Склад", kind: .warehouse,
            point: RoutePoint(latitude: 59, longitude: 30, address: "Невский, 100"))
        try database.savePlace(first)
        try database.savePlace(second)

        let oldTemplate = ParcelTemplate(name: "Старый", items: [
            .init(name: "А", currency: "RUB")])
        let newTemplate = ParcelTemplate(name: "Новый", items: [
            .init(name: "Б", currency: "RUB")])
        try database.saveParcelTemplate(oldTemplate)
        try database.saveParcelTemplate(newTemplate)

        // Unpinned state reads in insertion order.
        #expect(try database.readPlaces().map(\.name) == ["Дом", "Склад"])
        #expect(try database.readParcelTemplates().map(\.name) == ["Старый", "Новый"])

        try database.setPlacePinned(id: first.id, pinned: true)
        try database.setParcelTemplatePinned(id: newTemplate.id, pinned: true)

        #expect(try database.readPlaces().map(\.name) == ["Дом", "Склад"],
                "pinned-first: Дом was already first and stays")
        #expect(try database.readParcelTemplates().map(\.name) == ["Новый", "Старый"],
                "the pinned template leads despite being newer")

        // Re-saving the pinned door's destination adopts id *and* pin.
        try database.savePlace(SavedPlace(
            name: "Дом (черный вход)", kind: .home,
            point: RoutePoint(latitude: 55, longitude: 37, address: "Тверская, 6")))
        let places = try database.readPlaces()
        #expect(places.count == 2)
        #expect(places.first?.name == "Дом (черный вход)" && places.first?.pinned == true,
                "the adopted row keeps its pin through a re-save")
    }

    /// The tier split made observable, again: a library row syncs to the owner's
    /// private zone — a footprint exists — and is never part of a share.
    @Test("A template write leaves a private footprint, never shared")
    func templateWritesLeavePrivateMetadata() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        try database.saveParcelTemplate(ParcelTemplate(name: "Коробка", items: [
            .init(name: "А", currency: "RUB"),
        ]))

        let names = try syncedRecordNames(database)
        #expect(names.contains { $0.hasSuffix(":parcelTemplates") })
        #expect(names.contains { $0.hasSuffix(":parcelTemplateItems") },
                "the items child syncs privately beside its root")
    }

    /// A database born before the library gains `pinned` by the guarded ALTER —
    /// the pragma check, not luck; its rows read unpinned.
    @Test("A pre-pin savedPlaces table gains the column, places kept")
    func placePinMigrates() throws {
        let raw = try DatabaseQueue(
            path: directory.appendingPathComponent(AppDatabase.filename).path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE "savedPlaces" (
                  "id" TEXT PRIMARY KEY NOT NULL,
                  "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
                  "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
                  "address" TEXT NOT NULL,
                  "building" TEXT,
                  "entrance" TEXT, "floor" TEXT, "apartment" TEXT,
                  "intercom" TEXT,
                  "contactName" TEXT, "contactGivenName" TEXT,
                  "contactFamilyName" TEXT,
                  "contactPhone" TEXT, "contactPhoneExtension" TEXT
                ) STRICT;
                INSERT INTO "savedPlaces"
                  ("id", "name", "kind", "latitude", "longitude", "address")
                VALUES ('00000000-0000-0000-0000-0000000000d1',
                        'Дом', 'home', 55, 37, 'Тверская, 6');
                """)
        }

        let database = makeDatabase()
        let columns = try database.queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM pragma_table_info('savedPlaces')
                """)
        }
        #expect(columns.contains("pinned"), "the late column arrived by ALTER")

        let stored = try #require(database.readPlaces().first)
        #expect(stored.name == "Дом" && !stored.pinned,
                "a pre-pin row survives and reads unpinned")

        // Reopening is a no-op — the pragma guard absorbs the repeat.
        _ = try makeDatabase().queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM pragma_table_info('savedPlaces')
                """)
        }
    }

    /// The file-store contract: `places.json`/`saved-places.json` written before
    /// the flag carry no `pinned` key — a synthesized `decode` would read that
    /// as corruption and rescue bytes that were never wrong.
    @Test("A place blob written before the flag decodes unpinned, not corrupt")
    func legacyPlaceBlobDecodesUnpinned() throws {
        let json = """
            [{"id":"00000000-0000-0000-0000-0000000000d2","name":"Склад",
              "kind":"warehouse",
              "point":{"latitude":59,"longitude":30,"address":"Невский, 100"}}]
            """
        let places = try JSONDecoder().decode([SavedPlace].self, from: Data(json.utf8))
        #expect(places.first?.name == "Склад")
        #expect(places.first?.pinned == false,
                "absent reads as unpinned — the AddressParts rule")
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

    // MARK: Pending acceptances — YD-5's durable half

    @Test("A lost acceptance is noted, drained, and resolved into its order")
    func pendingAcceptanceLifecycle() throws {
        let database = makeDatabase()
        #expect(database.pendingAcceptances().isEmpty,
                "no attempts yet — the table starts empty")

        try database.noteUnresolvedAcceptance(claimID: "claim-lost")
        let pending = try #require(database.pendingAcceptances().first)
        #expect(pending.claimID == "claim-lost")
        #expect(pending.createdAt <= Date.now)
        #expect(pending.attempt == 1)

        let orderID = UUID()
        try database.markPendingAcceptance(pending, as: .resolved(orderID: orderID))
        #expect(database.pendingAcceptances().isEmpty,
                "resolved leaves the drain — the row stays as audit")

        let audit = try #require(database.queue.read {
            try Row.fetchOne($0, sql: """
                SELECT "state", "orderRef", "lastCheckedAt" FROM "pendingAcceptances"
                """)
        })
        #expect((audit["state"] as String?) == "resolved")
        #expect((audit["orderRef"] as UUID?) == orderID)
        #expect(audit["lastCheckedAt"] != nil,
                "the check is stamped — when it resolved is part of the record")
    }

    @Test("Noting the same claim twice is one row — a fresh attempt, not the first")
    func pendingAcceptanceIsIdempotent() throws {
        let database = makeDatabase()
        try database.noteUnresolvedAcceptance(claimID: "claim-lost")
        let first = try #require(database.pendingAcceptances().first)
        try database.markPendingAcceptance(first, as: .resolved(orderID: UUID()))
        try database.noteUnresolvedAcceptance(claimID: "claim-lost")

        let rows = database.pendingAcceptances()
        let second = try #require(rows.first)
        #expect(rows.count == 1, "the derived key absorbs the second note")
        #expect(second.claimID == "claim-lost")
        #expect(second.attempt == first.attempt + 1,
                "a re-note is a new attempt — drains match on it")
        #expect(second.createdAt >= first.createdAt,
                "the fresh attempt's deadline is its own, not the first loss's")
        let orderRef: UUID? = try database.queue.read {
            try Row.fetchOne($0, sql: """
                SELECT "orderRef" FROM "pendingAcceptances"
                """).flatMap { $0["orderRef"] }
        }
        #expect(orderRef == nil,
                "a re-pended row forgets the stale resolution's link")
    }

    /// The review's race: a re-note landing between the drain's read and its
    /// outcome write must survive — the mark matches the attempt it read, so a
    /// stale result cannot close the new attempt (PR #12).
    @Test("A stale drain outcome cannot close a re-noted attempt")
    func staleOutcomeCannotCloseNewAttempt() throws {
        let database = makeDatabase()
        try database.noteUnresolvedAcceptance(claimID: "claim-lost")
        let drained = try #require(database.pendingAcceptances().first)

        // The re-note lands mid-drain: the claim's answer is owed again.
        try database.noteUnresolvedAcceptance(claimID: "claim-lost")
        try database.markPendingAcceptance(drained, as: .lapsed)

        let rows = database.pendingAcceptances()
        #expect(rows.count == 1 && rows.first?.attempt == drained.attempt + 1,
                "the new attempt outlives the old result")
        #expect(rows.first?.claimID == "claim-lost")
    }

    @Test("A checked row keeps polling; a lapsed one leaves the drain")
    func pendingAcceptanceCheckedAndLapsed() throws {
        let database = makeDatabase()
        try database.noteUnresolvedAcceptance(claimID: "claim-a")
        try database.noteUnresolvedAcceptance(claimID: "claim-b")
        let rows = database.pendingAcceptances()
        let a = try #require(rows.first { $0.claimID == "claim-a" })
        let b = try #require(rows.first { $0.claimID == "claim-b" })

        try database.markPendingAcceptance(a, as: .checked)
        try database.markPendingAcceptance(b, as: .lapsed)

        #expect(database.pendingAcceptances().map(\.claimID) == ["claim-a"],
                "lapsed stops asking — the audit row outlives the poll")
        let lapsedState: String? = try database.queue.read {
            try Row.fetchOne($0, sql: """
                SELECT "state" FROM "pendingAcceptances" WHERE "claimID" = 'claim-b'
                """).map { $0["state"] }
        }
        #expect(lapsedState == "lapsed")
    }

    @Test("The identity boundary wipes pending acceptances with the rest")
    func pendingAcceptanceClearsAtIdentity() throws {
        let database = makeDatabase()
        try database.noteUnresolvedAcceptance(claimID: "claim-lost")
        try database.clearSyncState()
        #expect(database.pendingAcceptances().isEmpty,
                "the next credential never inherits this account's owed answer")
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

    /// Two transitions stamped at the same instant both belong on the timeline,
    /// but on replay neither may re-announce: the freshness gate passes equal
    /// stamps, so without `inserted` a cursor-reset replay would ping-pong
    /// banners between the two words (review, PR #7).
    @Test("Equal-time status replays never re-announce")
    func equalTimeReplaysStaySilent() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-eq")
        try database.recordOrder(order)

        let t = Date(timeIntervalSince1970: 1000)
        let accepted = ProviderEvent(
            orderID: order.id, providerEventID: 1, at: t,
            kind: "status", providerStatus: "accepted", source: "journal")
        let found = ProviderEvent(
            orderID: order.id, providerEventID: 2, at: t,
            kind: "status", providerStatus: "performer_found", source: "journal")

        #expect(try database.recordProviderEvent(accepted).statusAdvanced)
        #expect(try database.recordProviderEvent(found).statusAdvanced,
                "a genuinely new word announces even at an equal stamp")

        // Cursor-reset replay: both rows dedupe — neither can announce again.
        #expect(try database.recordProviderEvent(accepted) ==
                ProviderEventOutcome(inserted: false, statusAdvanced: false),
                "replaying the first equal-time word must not re-announce it")
        #expect(try database.recordProviderEvent(found) ==
                ProviderEventOutcome(inserted: false, statusAdvanced: false))

        // Replays arrive in feed order, so the equal-time tie resolves the same
        // way every pass — the mirror lands on the last feed word, unchanged.
        let mirror: Row? = try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT "providerStatus" FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        let status: String? = mirror?["providerStatus"]
        #expect(status == "performer_found")
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

    // MARK: Sharing — the per-order CKShare door

    /// The mock cloud runs the real sequence: `sendChanges()` flushes the fresh
    /// order's pending rows, metadata lands, `share(record:)` saves a `CKShare`
    /// into the mock database. What the test pins is the seam's own law —
    /// `publicPermission == .none` and the caller's title — so no call site can
    /// mint a public share (doc:Collaboration → "public sharing stays off").
    @Test("shareOrder produces a private share carrying the caller's title")
    func shareOrderIsPrivate() async throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-share")
        try database.recordOrder(order)

        try await withDependencies {
            $0.context = .test
        } operation: {
            try await database.syncEngine.start()
            let shared = try await database.shareOrder(id: order.id, title: "Заказ 4417")

            #expect(shared.share.publicPermission == .none,
                    "a public share is never this seam's product")
            #expect(shared.share[CKShare.SystemFieldKey.title] as? String == "Заказ 4417")
            #expect(try database.orderIsShared(order.id))
        }
    }

    /// The second tap is "manage sharing", not a second share — `share(record:)`
    /// returns the `CKShare` the metadata already knows, so the affordance can
    /// be one button for both meanings.
    @Test("Sharing an already-shared order returns the same share")
    func shareOrderIsIdempotent() async throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-share-2")
        try database.recordOrder(order)

        try await withDependencies {
            $0.context = .test
        } operation: {
            try await database.syncEngine.start()
            let first = try await database.shareOrder(id: order.id, title: "T")
            let second = try await database.shareOrder(id: order.id, title: "T")

            #expect(first.share.recordID == second.share.recordID)
        }
    }

    /// An id nothing has synced shares nothing — "not yet in iCloud" is the
    /// honest answer for a row that does not exist, rather than a minted share
    /// or the engine's generic sentence (issue #70).
    @Test("An unknown order cannot be shared")
    func unknownOrderShareFails() async throws {
        let database = makeDatabase()
        try await withDependencies {
            $0.context = .test
        } operation: {
            try await database.syncEngine.start()
            do {
                _ = try await database.shareOrder(id: UUID(), title: "T")
                Issue.record("nothing to share must refuse, not mint")
            } catch let error as AppDatabase.ShareError {
                guard case .notYetInCloud = error else {
                    Issue.record("expected .notYetInCloud, got \(error)")
                    return
                }
            }
        }
    }

    /// The stored start failure reaches the share ask by name — "sync never
    /// started, and here's the stored reason" — instead of the engine's generic
    /// sentence (issue #70). The duplicate index is the suite's standing way to
    /// make `startSync()` fail: the engine rejects the schema.
    @Test("A failed sync start makes shareOrder name the cause")
    func shareOrderNamesSyncStartFailure() async throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-share-fail")
        try database.recordOrder(order)
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX "shareFailDedup" ON "providerEvents"
                  ("orderID", "providerEventID")
                """)
        }
        try await withDependencies {
            $0.context = .test
        } operation: {
            await database.startSync()
            do {
                _ = try await database.shareOrder(id: order.id, title: "T")
                Issue.record("a share past a failed start must refuse")
            } catch let error as AppDatabase.ShareError {
                guard case .syncNotStarted = error else {
                    Issue.record("expected .syncNotStarted, got \(error)")
                    return
                }
                #expect(error.errorDescription?.isEmpty == false)
                #expect(error.recoverySuggestion?.isEmpty == false,
                        "a filled error can be displayed as is — remedy included")
            }
        }
    }

    /// An order never pushed — the engine never started, or the upload never
    /// landed — reports "not yet in iCloud", which is also where a signed-out
    /// device lands: `start()` swallows a missing account silently.
    @Test("An unsynced order reports not-yet-in-iCloud, not a mystery")
    func shareOrderNamesUnsyncedOrder() async throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-share-unsynced")
        try database.recordOrder(order)
        try await withDependencies {
            $0.context = .test
        } operation: {
            do {
                _ = try await database.shareOrder(id: order.id, title: "T")
                Issue.record("an order iCloud never saw must refuse")
            } catch let error as AppDatabase.ShareError {
                guard case .notYetInCloud = error else {
                    Issue.record("expected .notYetInCloud, got \(error)")
                    return
                }
            }
        }
    }

    /// The engine's own refusal carries its words through — the only surface it
    /// offers — rather than being dropped for a generic retry hint.
    @Test("ShareError.refused forwards the underlying error's words")
    func shareErrorRefusedForwardsUnderlying() {
        let underlying = CocoaError(.coderInvalidValue)
        let error = AppDatabase.ShareError.refused(underlying)
        #expect(error.recoverySuggestion == underlying.localizedDescription)
    }

    // MARK: Strings — each half resolves its own bundle

    /// The data half reads its words from `YDeliveryKit_YDeliveryData.bundle`;
    /// an unresolvable lookup would fatalError before the expectations ran
    /// (issue #28). The UI half's `.kit` resolves beside it — same check.
    @Test("Both bundle descriptions resolve in the test host")
    func bundleDescriptionsResolve() {
        #expect(String(localized: LocalizedStringResource("Picked up", bundle: .data)) == "Picked up")
        #expect(String(localized: LocalizedStringResource("Draft", bundle: .kit)) == "Draft")
    }

    /// Unsharing removes the share the metadata recorded — the affordance's
    /// "share/manage" label flips back. `acceptShare` carries no mock test:
    /// `CKShare.Metadata` is system-vended with no public initializer, so the
    /// seam is verified on device (doc:Collaboration's device pass). The
    /// `.unknownItem` tolerance — `CloudSharingView`'s Stop Sharing deleting
    /// the share outside this seam and `unshareOrder` clearing the stale
    /// cache anyway — needs a remote delete this test can't reach through
    /// public API; same device-pass debt.
    @Test("Unsharing a shared order clears its share")
    func unshareClearsShare() async throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-share-3")
        try database.recordOrder(order)

        try await withDependencies {
            $0.context = .test
        } operation: {
            try await database.syncEngine.start()
            _ = try await database.shareOrder(id: order.id, title: "T")
            try await database.unshareOrder(id: order.id)

            #expect(try !database.orderIsShared(order.id),
                    "the metadata's share is gone — the order is private again")
        }
    }

    // MARK: - The chat stream

    /// Text, photo and structured kinds are one stream, oldest first — the
    /// same read the chat surface and the receiver's history draw.
    @Test("A posted stream reads back in order — text, photo, confirmation")
    func postedMessagesReadBack() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-chat-1")
        try database.recordOrder(order)

        try database.postMessage(OrderMessage(
            orderID: order.id,
            sentAt: Date(timeIntervalSince1970: 100),
            kind: OrderMessage.Kind.text,
            text: "Подъезд со двора", authorHint: "Ирина"))
        let photo = try database.postPhotoMessage(
            orderID: order.id, data: Data([1, 2, 3]),
            sentAt: Date(timeIntervalSince1970: 200),
            caption: "Коробка помята", authorHint: "Ирина")
        try database.postMessage(OrderMessage(
            orderID: order.id,
            sentAt: Date(timeIntervalSince1970: 300),
            kind: OrderMessage.Kind.receptionConfirmed,
            authorHint: "Ирина"))

        let messages = try database.messages(orderID: order.id)
        #expect(messages.map(\.kind) == [
            OrderMessage.Kind.text, OrderMessage.Kind.photo,
            OrderMessage.Kind.receptionConfirmed])
        #expect(messages[0].text == "Подъезд со двора")
        #expect(messages[2].authorHint == "Ирина")

        #expect(photo.kind == OrderMessage.Kind.photo)
        let payload = try #require(photo.attachmentRef,
                                   "a photo message names its payload")
        #expect(try database.attachmentData(payload) == Data([1, 2, 3]))
    }

    /// `attachmentRef` is a value column — `PRAGMA foreign_keys` stays off, so
    /// the write boundary checks the payload names the same order rather than
    /// trusting it.
    @Test("A photo reference to another order's payload is refused")
    func crossOrderAttachmentRefused() throws {
        let database = makeDatabase()
        let first = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-chat-2")
        let second = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 56, longitude: 38, address: "Б")],
            claimID: "claim-chat-3")
        try database.recordOrder(first)
        try database.recordOrder(second)
        let photo = try database.postPhotoMessage(
            orderID: first.id, data: Data([9]))

        #expect(throws: AppDatabase.WriteError.attachmentOutsideOrder) {
            try database.postMessage(OrderMessage(
                orderID: second.id, kind: OrderMessage.Kind.photo,
                attachmentRef: photo.attachmentRef))
        }
        #expect(try database.messages(orderID: second.id).isEmpty,
                "the refused post left nothing behind")
    }

    /// No FK enforcement means nothing else stops a post for a phantom order —
    /// and its dangling row would sync to every share. The boundary refuses.
    @Test("A message for an order that isn't a row is refused")
    func phantomOrderMessageRefused() throws {
        let database = makeDatabase()
        #expect(throws: AppDatabase.WriteError.messageHasNoOrder) {
            try database.postMessage(OrderMessage(
                orderID: UUID(), kind: OrderMessage.Kind.text, text: "алло"))
        }
    }

    /// A `photo` post without its payload is a frame with nothing in it —
    /// photo messages arrive whole through `postPhotoMessage` or not at all.
    @Test("A photo message with no payload is refused")
    func payloadlessPhotoRefused() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-chat-5")
        try database.recordOrder(order)

        #expect(throws: AppDatabase.WriteError.photoMessageHasNoPayload) {
            try database.postMessage(OrderMessage(
                orderID: order.id, kind: OrderMessage.Kind.photo))
        }
    }

    /// Chat is the participant's activity: it never writes `lastActivityAt`
    /// (owner's provider stamp), yet a fresh message must still lift the
    /// order in the list — ordering is derived at read, per the contract.
    @Test("A fresh message lifts its order in the list without touching the stamp")
    func messageLiftsOrderInReadOrder() throws {
        let database = makeDatabase()
        let older = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-chat-6")
        let newer = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 56, longitude: 38, address: "Б")],
            claimID: "claim-chat-7")
        try database.recordOrder(older)
        try database.recordOrder(newer)
        #expect(try database.readOrders().first?.id == newer.id,
                "the newer stamp leads before any chat")

        try database.postMessage(OrderMessage(
            orderID: older.id,
            sentAt: Date().addingTimeInterval(60),
            kind: OrderMessage.Kind.text, text: "гружусь"))

        #expect(try database.readOrders().first?.id == older.id,
                "the message's sentAt derived the new order — the stamp stayed put")
    }

    /// Chat rows ride the order's share tree like every other single-FK child —
    /// the footprint test pins the tagging, so a participant's message is
    /// provably *inside* the share, not broadcast outside it.
    @Test("A posted message leaves a share-tree footprint on the order")
    func messageLeavesShareTreeFootprint() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-chat-4")
        try database.recordOrder(order)
        try database.postMessage(OrderMessage(
            orderID: order.id, kind: OrderMessage.Kind.text, text: "жду"))

        let names = try syncedRecordNames(database)
        #expect(names.contains { $0.hasSuffix(":orderMessages") },
                "the message row is tagged for sync under the order's tree")
        let parents = try parentRecordNames(database)
        #expect(parents.contains { $0?.hasSuffix(":orders") == true })
    }
}

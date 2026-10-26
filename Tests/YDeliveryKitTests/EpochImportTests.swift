import Dependencies
import Foundation
import GRDB
import Testing
import YDeliveryKit

/// Schema epoch 2 (doc:Schema → "Epoch 2"): a store from before the epoch found
/// beside the new file is copied into it once, on first open, and marked aside —
/// bytes are never destroyed. Each test builds a pre-epoch file with the 0.4.15
/// DDL (the shape the two TestFlight testers carry) and writes raw rows into it,
/// so the import is exercised against the file a device actually has.
@Suite("Epoch import")
struct EpochImportTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EpochImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase() -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test")
    }

    private var legacyURL: URL {
        directory.appendingPathComponent(AppDatabase.legacyFilename)
    }

    private func directoryListing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: The fixture — the 0.4.15 shape, one row per table

    static let orderID = "00000000-0000-0000-0000-00000000aa01"
    static let stopID = "00000000-0000-0000-0000-00000000bb01"
    static let attachmentID = "00000000-0000-0000-0000-00000000cc01"
    static let draftID = "00000000-0000-0000-0000-00000000dd01"
    static let templateID = "00000000-0000-0000-0000-00000000ee01"
    static let fieldID = "00000000-0000-0000-0000-00000000ff01"

    /// Writes the pre-epoch store: the DDL as 0.4.15 spelled it (REPLACE clauses and
    /// `providerEvents` included) and one fully populated row per table.
    private func writeLegacyStore(shape: LegacyShape = .full) throws {
        let raw = try DatabaseQueue(path: legacyURL.path)
        try raw.write { db in
            try db.execute(sql: shape.ddl)
            try db.execute(sql: shape.rows)
        }
        // The hidden sqlite-data metadatabase a synced store keeps beside itself —
        // any bytes will do; the import marks it aside with the store.
        try Data("not a real metadatabase".utf8).write(
            to: directory.appendingPathComponent(".ydelivery.metadata-iCloud.old.sqlite"))
    }

    // MARK: The happy path

    @Test("Every tier of a pre-epoch store reads back through the new one")
    func importsEveryTier() throws {
        try writeLegacyStore()
        let database = makeDatabase()

        let orders = try database.readOrders()
        let order = try #require(orders.first)
        #expect(orders.count == 1)
        #expect(order.id.uuidString.lowercased() == Self.orderID)
        #expect(order.status == .done && order.claimID == "claim-legacy")
        #expect(order.price == "850.00" && order.tariff == "courier")
        #expect(order.route.count == 2, "both stops crossed the epoch")
        #expect(order.route.first?.address == "Тверская, 6")
        #expect(order.route.first?.visit?.status == .visited,
                "the provider's visit record rides along")
        #expect(order.isArchived, "the private tier's shelf survives")
        #expect(order.courierName == "Сергей")

        let events = try database.events(orderID: order.id)
        #expect(events.count == 1, "providerEvents landed in orderEvents")
        #expect(events.first?.providerStatus == "delivered_finish")
        #expect(events.first?.providerEventID == 7)
        #expect(events.first?.authorRef == nil && events.first?.routeDigest == nil,
                "an imported event is history nobody signed — the epoch's columns stay NULL")

        let messages = try database.messages(orderID: order.id)
        #expect(messages.count == 1 && messages.first?.text == "Курьер у ворот")
        #expect(try database.attachmentData(
            UUID(uuidString: Self.attachmentID)!) == Data([0x89, 0x50, 0x4E, 0x47]))

        #expect(try database.readPlaces().first?.name == "Дом")
        #expect(try database.readPlaces().first?.pinned == true)
        let template = try #require(try database.readParcelTemplates().first)
        #expect(template.name == "Коробка" && template.items.count == 1)
        #expect(try database.fieldDefinitions().first?.name == "Заказ")
        #expect(try database.orderCustomFields(orderID: order.id).first?.value == "4417")
        #expect(try database.orderNumber(for: order.id) == "4417")

        let draft = try #require(try database.currentDraft())
        #expect(draft.stops.count == 2 && draft.items.count == 1)
        #expect(draft.fieldValues.count == 1 && draft.chosenTariff == "cargo")
        #expect(database.readSyncState().cursor == "eyJ-legacy-cursor")
        #expect(database.readSyncState().pendingClaimIDs == ["claim-pending"])
        #expect(database.pendingAcceptances().first?.claimID == "claim-lost")

        let listing = try directoryListing()
        #expect(listing.contains(AppDatabase.filename), "the new store exists")
        #expect(!listing.contains(AppDatabase.legacyFilename), "the old store was marked aside")
        #expect(listing.contains(where: { $0.hasPrefix("ydelivery.sqlite.imported-") }),
                "marked, never deleted")
        #expect(listing.contains(where: { $0.hasPrefix(".ydelivery.metadata-iCloud.old.sqlite.imported-") }),
                "the old metadatabase was marked with it")
        #expect(!listing.contains(".ydelivery.metadata-iCloud.old.sqlite"))
    }

    @Test("A second pass over the same old store writes nothing")
    func importIsIdempotent() throws {
        try writeLegacyStore()
        _ = try makeDatabase().readOrders()
        // Simulate a run that died after the commit and before the rename: the old
        // store is back under its name, with the new store already holding its rows.
        let marked = try #require(try directoryListing().first(where: { $0.hasPrefix("ydelivery.sqlite.imported-") }))
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent(marked), to: legacyURL)

        let database = makeDatabase()
        #expect(try database.readOrders().count == 1)
        #expect(try database.events(orderID: UUID(uuidString: Self.orderID)!).count == 1)
        #expect(try database.messages(orderID: UUID(uuidString: Self.orderID)!).count == 1)
        #expect(try database.readPlaces().count == 1)
        let imported = try directoryListing().filter { $0.hasPrefix("ydelivery.sqlite.imported-") }
        #expect(imported.count == 2, "the retried store is marked aside beside the first mark")
    }

    @Test("A store from an older pre-epoch shape imports the columns it has")
    func importsAnOlderShape() throws {
        try writeLegacyStore(shape: .earlyPhase3)
        let database = makeDatabase()
        let order = try #require(try database.readOrders().first)
        #expect(order.status == .active && order.route.count == 1)
        #expect((order.route.first?.addressParts?.building ?? "").isEmpty,
                "a column the old shape lacked reads as absent, not as a failure")
        #expect(try database.orderNumber(for: order.id) == "4417",
                "the carrier backfill the ALTER list carried still runs for a pre-carrier store")
        #expect(try database.readPlaces().first?.pinned == false,
                "pre-pin places read unpinned")
    }

    @Test("A file that is not a database is rescued aside; the store opens empty")
    func notADatabaseIsRescued() throws {
        try Data("definitely not sqlite".utf8).write(to: legacyURL)
        let database = makeDatabase()
        #expect(try database.readOrders().isEmpty)
        let listing = try directoryListing()
        #expect(!listing.contains(AppDatabase.legacyFilename))
        #expect(listing.contains(where: { $0.hasPrefix("ydelivery.sqlite.corrupted-") }),
                "bytes are never destroyed — rescued, not deleted")
    }

    @Test("No pre-epoch store means no import and no marks")
    func nothingToImport() throws {
        let database = makeDatabase()
        #expect(try database.readOrders().isEmpty)
        #expect(try directoryListing().allSatisfy { !$0.contains(".imported-") })
    }

    // MARK: The epoch's own shape

    @Test("No shared-tier primary key carries ON CONFLICT REPLACE")
    func sharedKeysCarryNoReplaceClause() throws {
        let database = makeDatabase()
        let shared = ["orders", "routeStops", "orderItems", "orderCustomFields",
                      "orderEvents", "orderMessages", "orderAttachments",
                      "participantKeys", "memberships", "orderRatings"]
        let definitions = try database.queue.read { db in
            var definitions: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT "name", "sql" FROM sqlite_master WHERE "type" = 'table'
                """) {
                let name: String = row["name"]
                definitions[name] = row["sql"]
            }
            return definitions
        }
        for table in shared {
            let sql = try #require(definitions[table], "\(table) exists")
            #expect(!sql.uppercased().contains("ON CONFLICT REPLACE"),
                    "\(table): a colliding insert must never replace a row silently")
        }
        #expect(definitions["providerEvents"] == nil, "the feed is orderEvents now")
        #expect(definitions["pendingDiscoveries"]?.contains("UNIQUE") == true,
                "the device tier keeps its dedupe constraint")
    }

    @Test("A retried message post is one row — INSERT OR IGNORE, not REPLACE")
    func messageRetryIsOneRow() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-retry")
        try database.recordOrder(order)
        let message = OrderMessage(orderID: order.id, kind: OrderMessage.Kind.text, text: "первое")
        try database.postMessage(message)
        var retried = message
        retried.text = "второе под тем же id"
        try database.postMessage(retried)
        let stored = try database.messages(orderID: order.id)
        #expect(stored.count == 1 && stored.first?.text == "первое",
                "the first row stands; a retry with the same id changes nothing")
    }

    @Test("A photo post stores the payload's hash beside the row")
    func photoPostHashesItsPayload() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-photo")
        try database.recordOrder(order)
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let posted = try database.postPhotoMessage(orderID: order.id, data: data)
        let hash: String? = try database.queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT "dataHash" FROM "orderAttachments" WHERE "id" = ?
                """, arguments: AppDatabase.args([posted.attachmentRef]))
        }
        #expect(hash == AppDatabase.dataHash(of: data))
        #expect(hash?.count == 64, "hex SHA-256")
    }

    @Test("An event's identity carries the provider's revision and the route digest, never its source")
    func eventIdentityIsTheFact() {
        let order = UUID()
        let card = OrderEvent(orderID: order, providerRevision: 3, at: .now, kind: OrderEvent.Kind.sighting,
                              providerStatus: "accepted", source: OrderEvent.Source.card,
                              routeDigest: "ab12")
        let search = OrderEvent(orderID: order, providerRevision: 3, at: .now, kind: OrderEvent.Kind.sighting,
                                providerStatus: "accepted", source: OrderEvent.Source.search,
                                routeDigest: "ab12")
        #expect(card.id == search.id, "a card read and a search read of one revision are one observation")
        let later = OrderEvent(orderID: order, providerRevision: 4, at: .now, kind: OrderEvent.Kind.sighting,
                               providerStatus: "accepted", source: OrderEvent.Source.card,
                               routeDigest: "ab12")
        #expect(later.id != card.id, "a later revision is a new fact even when nothing else changed")
        let rerouted = OrderEvent(orderID: order, providerRevision: 3, at: .now, kind: OrderEvent.Kind.sighting,
                                  providerStatus: "accepted", source: OrderEvent.Source.card,
                                  routeDigest: "cd34")
        #expect(rerouted.id != card.id, "a corrected route is a new signed sighting")
        let journal = OrderEvent(orderID: order, providerEventID: 71, at: .now,
                                 kind: OrderEvent.Kind.statusChanged, providerStatus: "pickuped",
                                 source: OrderEvent.Source.journal)
        let replayed = OrderEvent(orderID: order, providerEventID: 71, at: .now,
                                  kind: OrderEvent.Kind.statusChanged, providerStatus: "pickuped",
                                  source: OrderEvent.Source.journal)
        #expect(journal.id == replayed.id, "a replayed page re-derives the same key")
        let signed = OrderEvent(orderID: order, providerEventID: 71, at: .now,
                                kind: OrderEvent.Kind.statusChanged, providerStatus: "pickuped",
                                source: OrderEvent.Source.journal, writerKeyID: "p256.v2.0123456789abcdef")
        #expect(signed.id != journal.id, "the writer's key joins the derivation once there is one")
    }

    @Test("The device's party round-trips under its authority")
    func localIdentityRoundTrips() throws {
        let database = makeDatabase()
        let party = UUID.partyRef(authority: "cloudkit", subject: "_abc123")
        #expect(party == UUID.partyRef(authority: "cloudkit", subject: "_abc123"),
                "derived alike every time, on every device")
        #expect(try database.localIdentity(authority: "cloudkit:iCloud.test") == nil)
        try database.noteLocalIdentity(authority: "cloudkit:iCloud.test", subject: "_abc123", partyRef: party)
        let stored = try #require(try database.localIdentity(authority: "cloudkit:iCloud.test"))
        #expect(stored.subject == "_abc123" && stored.partyRef == party)
        // A new account on the device replaces the row under the same authority.
        let other = UUID.partyRef(authority: "cloudkit", subject: "_def456")
        try database.noteLocalIdentity(authority: "cloudkit:iCloud.test", subject: "_def456", partyRef: other)
        #expect(try database.localIdentity(authority: "cloudkit:iCloud.test")?.partyRef == other)
    }

    @Test("The epoch's tables are registered with the engine and pass its validation")
    func engineAcceptsTheEpochSchema() throws {
        let database = makeDatabase()
        try withDependencies {
            $0.context = .test
        } operation: {
            _ = try database.syncEngine
        }
    }
}

// MARK: - Pre-epoch fixtures

/// The DDL as the pre-epoch Kit spelled it, with one row per table. `.full` is
/// 0.4.15 — the shape the TestFlight testers carry; `.earlyPhase3` predates
/// `building`, `pinned`, `carrier`, `archivedAt`, the courier and visit columns,
/// the way a store last opened by 0.3.x would.
enum LegacyShape {
    case full
    case earlyPhase3

    var ddl: String {
        switch self {
        case .full: Self.fullDDL
        case .earlyPhase3: Self.earlyDDL
        }
    }

    var rows: String {
        switch self {
        case .full: Self.fullRows
        case .earlyPhase3: Self.earlyRows
        }
    }

    private static let o = EpochImportTests.orderID
    private static let s = EpochImportTests.stopID
    private static let a = EpochImportTests.attachmentID
    private static let d = EpochImportTests.draftID
    private static let t = EpochImportTests.templateID
    private static let f = EpochImportTests.fieldID

    static let fullDDL = """
        CREATE TABLE "orders" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "createdAt" REAL NOT NULL, "providerAccountRef" TEXT,
          "provider" TEXT NOT NULL, "lastActivityAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE "orderProviderStates" (
          "orderID" TEXT PRIMARY KEY NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "claimID" TEXT, "corpClientID" TEXT, "status" TEXT NOT NULL,
          "providerStatus" TEXT, "providerDetail" TEXT,
          "tariff" TEXT, "price" TEXT, "currency" TEXT,
          "courierName" TEXT, "courierVehicle" TEXT, "etaMinutes" INTEGER,
          "dueAt" REAL, "finishedAt" REAL, "providerObservedAt" REAL, "mirroredAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE "orderOptions" (
          "orderID" TEXT PRIMARY KEY NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "proCourier" INTEGER NOT NULL, "toDoor" INTEGER NOT NULL,
          "thermobag" INTEGER NOT NULL, "loaders" INTEGER NOT NULL,
          "due" REAL, "comment" TEXT NOT NULL
        ) STRICT;
        CREATE TABLE "routeStops" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL, "address" TEXT NOT NULL,
          "building" TEXT, "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT,
          "visitStatus" TEXT, "visitedAt" REAL, "expectedVisitAt" REAL
        ) STRICT;
        CREATE TABLE "orderItems" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL,
          "pickupStopRef" TEXT, "dropoffStopRef" TEXT
        ) STRICT;
        CREATE TABLE "orderCustomFields" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "name" TEXT NOT NULL, "value" TEXT NOT NULL, "carrier" TEXT
        ) STRICT;
        CREATE TABLE "providerEvents" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "providerEventID" INTEGER, "at" REAL NOT NULL,
          "kind" TEXT NOT NULL, "providerStatus" TEXT, "detail" TEXT, "source" TEXT NOT NULL
        ) STRICT;
        CREATE TABLE "orderMessages" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "sentAt" REAL NOT NULL, "kind" TEXT NOT NULL,
          "text" TEXT, "attachmentRef" TEXT, "authorHint" TEXT
        ) STRICT;
        CREATE TABLE "orderAttachments" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "kind" TEXT NOT NULL, "caption" TEXT, "byteSize" INTEGER,
          "createdAt" REAL NOT NULL, "authorHint" TEXT
        ) STRICT;
        CREATE TABLE "attachmentBlobs" (
          "attachmentID" TEXT PRIMARY KEY NOT NULL REFERENCES "orderAttachments"("id") ON DELETE CASCADE,
          "data" BLOB NOT NULL
        ) STRICT;
        CREATE TABLE "providerAccounts" (
          "key" TEXT PRIMARY KEY NOT NULL, "provider" TEXT NOT NULL, "corpClientID" TEXT,
          "displayLabel" TEXT, "firstSeenAt" REAL, "lastSeenAt" REAL
        ) STRICT;
        CREATE TABLE "orderPrivateStates" (
          "orderID" TEXT PRIMARY KEY NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "personalNote" TEXT, "pinned" INTEGER NOT NULL, "lastSeenActivityAt" REAL, "archivedAt" REAL
        ) STRICT;
        CREATE TABLE "savedPlaces" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "pinned" INTEGER NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL, "address" TEXT NOT NULL,
          "building" TEXT, "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        CREATE TABLE "customFieldDefinitions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "choicesJSON" TEXT NOT NULL,
          "isOptional" INTEGER NOT NULL, "isShownByDefault" INTEGER NOT NULL,
          "carrier" TEXT NOT NULL, "position" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE "parcelTemplates" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "pinned" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE "parcelTemplateItems" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "templateID" TEXT NOT NULL REFERENCES "parcelTemplates"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL
        ) STRICT;
        CREATE TABLE "syncStates" (
          "providerAccountRef" TEXT PRIMARY KEY NOT NULL,
          "journalCursor" TEXT, "historyBackfilled" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE "pendingDiscoveries" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "providerAccountRef" TEXT NOT NULL, "claimID" TEXT NOT NULL,
          "firstSeenAt" REAL NOT NULL, "lastAttemptAt" REAL,
          UNIQUE("providerAccountRef", "claimID")
        ) STRICT;
        CREATE TABLE "pendingAcceptances" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "providerAccountRef" TEXT NOT NULL, "claimID" TEXT, "orderRef" TEXT,
          "createdAt" REAL NOT NULL, "lastCheckedAt" REAL, "state" TEXT NOT NULL,
          "attempt" INTEGER NOT NULL DEFAULT 1
        ) STRICT;
        CREATE TABLE "orderDrafts" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "createdAt" REAL NOT NULL,
          "proCourier" INTEGER NOT NULL, "toDoor" INTEGER NOT NULL,
          "thermobag" INTEGER NOT NULL, "loaders" INTEGER NOT NULL,
          "due" REAL, "comment" TEXT NOT NULL, "chosenTariff" TEXT
        ) STRICT;
        CREATE TABLE "draftStops" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL REFERENCES "orderDrafts"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL, "longitude" REAL, "address" TEXT,
          "building" TEXT, "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        CREATE TABLE "draftItems" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL REFERENCES "orderDrafts"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL,
          "pickupStopRef" TEXT, "dropoffStopRef" TEXT
        ) STRICT;
        CREATE TABLE "draftCustomFields" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL REFERENCES "orderDrafts"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "value" TEXT
        ) STRICT;
        """

    static let fullRows = """
        INSERT INTO "orders" VALUES ('\(o)', 1700000000, 'yandex:legacy', 'yandex', 1700003600);
        INSERT INTO "orderProviderStates" VALUES ('\(o)', 'claim-legacy', 'corp-1', 'done',
          'delivered_finish', '{"resolution":"success"}', 'courier', '850.00', 'RUB',
          'Сергей', 'м 234 ор 77', NULL, NULL, 1700003500, 1700003500, 1700003600);
        INSERT INTO "orderOptions" VALUES ('\(o)', 0, 1, 0, 0, NULL, 'позвонить за 10 минут');
        INSERT INTO "routeStops" VALUES ('\(s)', '\(o)', 0, 'pickup', 55.7576, 37.6137, 'Тверская, 6',
          'к. 1', '2', '3', '45', '45#', 'Иван Петров', 'Иван', 'Петров', '+79990000001', NULL,
          'visited', 1700001000, NULL);
        INSERT INTO "routeStops" VALUES ('00000000-0000-0000-0000-00000000bb02', '\(o)', 1, 'dropoff',
          55.7658, 37.5946, 'Тверская-Ямская, 12', NULL, NULL, NULL, NULL, NULL,
          'Ирина', 'Ирина', NULL, '+79990000002', NULL, 'visited', 1700003400, NULL);
        INSERT INTO "orderItems" VALUES ('00000000-0000-0000-0000-00000000ab01', '\(o)', 'Документы', 1,
          0.5, '1000', 'RUB', 30, 20, 2, NULL, NULL);
        INSERT INTO "orderCustomFields" VALUES ('00000000-0000-0000-0000-00000000cf01', '\(o)', '\(f)',
          'Заказ', '4417', 'orderNumber');
        INSERT INTO "providerEvents" VALUES ('00000000-0000-0000-0000-00000000e001', '\(o)', 7, 1700003500,
          'status_changed', 'delivered_finish', 'success', 'journal');
        INSERT INTO "orderMessages" VALUES ('00000000-0000-0000-0000-000000000501', '\(o)', 1700002000,
          'text', 'Курьер у ворот', NULL, 'Ирина');
        INSERT INTO "orderAttachments" VALUES ('\(a)', '\(o)', 'photo', 'Коробка у двери', 4, 1700002100, 'Ирина');
        INSERT INTO "attachmentBlobs" VALUES ('\(a)', X'89504E47');
        INSERT INTO "providerAccounts" VALUES ('yandex:legacy', 'yandex', 'corp-1', 'Склад', 1699000000, 1700003600);
        INSERT INTO "orderPrivateStates" VALUES ('\(o)', 'заметка', 1, 1700003600, 1700004000);
        INSERT INTO "savedPlaces" VALUES ('00000000-0000-0000-0000-000000005001', 'Дом', 'home', 1,
          55.7576, 37.6137, 'Тверская, 6', 'к. 1', '2', '3', '45', '45#',
          'Иван Петров', 'Иван', 'Петров', '+79990000001', NULL);
        INSERT INTO "customFieldDefinitions" VALUES ('\(f)', 'Заказ', 'text', '[]', 0, 1, 'orderNumber', 0);
        INSERT INTO "parcelTemplates" VALUES ('\(t)', 'Коробка', 0);
        INSERT INTO "parcelTemplateItems" VALUES ('00000000-0000-0000-0000-000000007101', '\(t)', 0,
          'Коробка', 1, 2.5, '500', 'RUB', 40, 30, 20);
        INSERT INTO "syncStates" VALUES ('test:unattributed', 'eyJ-legacy-cursor', 1);
        INSERT INTO "pendingDiscoveries" VALUES ('00000000-0000-0000-0000-000000009d01', 'test:unattributed',
          'claim-pending', 1700003000, NULL);
        INSERT INTO "pendingAcceptances" VALUES ('00000000-0000-0000-0000-000000009a01', 'test:unattributed',
          'claim-lost', NULL, 1700003100, NULL, 'pending', 1);
        INSERT INTO "orderDrafts" VALUES ('\(d)', 1700005000, 0, 1, 0, 0, NULL, '', 'cargo');
        INSERT INTO "draftStops" VALUES ('00000000-0000-0000-0000-00000000d501', '\(d)', 0, 'pickup',
          55.75, 37.61, 'Арбат, 1', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        INSERT INTO "draftStops" VALUES ('00000000-0000-0000-0000-00000000d502', '\(d)', 1, 'dropoff',
          NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        INSERT INTO "draftItems" VALUES ('00000000-0000-0000-0000-00000000d101', '\(d)', 'Пакет', 1,
          NULL, NULL, 'RUB', NULL, NULL, NULL, NULL, NULL);
        INSERT INTO "draftCustomFields" VALUES ('00000000-0000-0000-0000-00000000dc01', '\(d)', '\(f)', '4418');
        """

    /// A store last written before `building`, `pinned`, `carrier`, `archivedAt`,
    /// the courier columns and the visit columns existed.
    static let earlyDDL = """
        CREATE TABLE "orders" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "createdAt" REAL NOT NULL, "providerAccountRef" TEXT,
          "provider" TEXT NOT NULL, "lastActivityAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE "orderProviderStates" (
          "orderID" TEXT PRIMARY KEY NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "claimID" TEXT, "corpClientID" TEXT, "status" TEXT NOT NULL,
          "providerStatus" TEXT, "providerDetail" TEXT,
          "tariff" TEXT, "price" TEXT, "currency" TEXT,
          "dueAt" REAL, "finishedAt" REAL, "providerObservedAt" REAL, "mirroredAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE "routeStops" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL, "address" TEXT NOT NULL,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        CREATE TABLE "orderCustomFields" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL REFERENCES "orders"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "name" TEXT NOT NULL, "value" TEXT NOT NULL
        ) STRICT;
        CREATE TABLE "customFieldDefinitions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "choicesJSON" TEXT NOT NULL,
          "isOptional" INTEGER NOT NULL, "isShownByDefault" INTEGER NOT NULL,
          "carrier" TEXT NOT NULL, "position" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE "savedPlaces" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL, "address" TEXT NOT NULL,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        """

    static let earlyRows = """
        INSERT INTO "orders" VALUES ('\(o)', 1690000000, NULL, 'yandex', 1690000000);
        INSERT INTO "orderProviderStates" VALUES ('\(o)', 'claim-early', NULL, 'active',
          'pickuped', NULL, 'express', '1240', 'RUB', NULL, NULL, 1690000000, 1690000000);
        INSERT INTO "routeStops" VALUES ('\(s)', '\(o)', 0, 'pickup', 55.75, 37.61, 'Арбат, 1',
          NULL, NULL, NULL, NULL, 'Иван', 'Иван', NULL, '+79990000001', NULL);
        INSERT INTO "orderCustomFields" VALUES ('00000000-0000-0000-0000-00000000cf01', '\(o)', '\(f)',
          'Заказ', '4417');
        INSERT INTO "customFieldDefinitions" VALUES ('\(f)', 'Заказ', 'text', '[]', 0, 1, 'orderNumber', 0);
        INSERT INTO "savedPlaces" VALUES ('00000000-0000-0000-0000-000000005001', 'Дом', 'home',
          55.75, 37.61, 'Арбат, 1', NULL, NULL, NULL, NULL, 'Иван', 'Иван', NULL, '+79990000001', NULL);
        """
}

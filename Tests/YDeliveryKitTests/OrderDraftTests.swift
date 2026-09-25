import Foundation
import GRDB
import Testing
import YDeliveryKit

/// The parked-draft store (YDelivery YD-16): a force-quit mid-draft must lose
/// nothing the sender typed — route holes, door contacts, parcel journeys, the
/// «Ваши поля» disclosure state all ride the same rows.
@Suite("Order drafts")
struct OrderDraftTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrderDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase() -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test")
    }

    /// A draft exercising every column: a filled pickup, a filled drop-off, one
    /// stop still a hole, an item with a named journey, options off their
    /// defaults, a remembered class, and both kinds of field row.
    private func fullDraft() -> OrderDraft {
        let pickup = OrderDraft.Stop(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            role: "pickup",
            point: RoutePoint(
                latitude: 55.7558, longitude: 37.6173,
                address: "Москва, Тверская 1",
                addressParts: AddressParts(entrance: "2", floor: "", apartment: "15", intercom: "77"),
                contactName: "Иван Петров", contactGivenName: "Иван",
                contactFamilyName: "Петров", contactPhone: "+79123456789",
                contactPhoneExtension: "12"))
        let dropoff = OrderDraft.Stop(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            role: "dropoff",
            point: RoutePoint(
                latitude: 59.9386, longitude: 30.3141, address: "Санкт-Петербург, Невский 20"))
        let hole = OrderDraft.Stop(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            role: "dropoff")
        let fieldRef = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let revealedOnly = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        var draft = OrderDraft(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        draft.proCourier = true
        draft.toDoor = false
        draft.thermobag = true
        draft.loaders = 2
        draft.due = Date(timeIntervalSince1970: 1_700_003_600)
        draft.comment = "Домофон не работает"
        draft.chosenTariff = "cargo"
        draft.stops = [pickup, dropoff, hole]
        draft.items = [OrderDraft.Item(
            name: "Коробка", quantity: 2, weightKg: 3.5, cost: "2500.00",
            currency: "RUB", sizeLengthCm: 25, sizeWidthCm: 18, sizeHeightCm: 15,
            pickupStopRef: pickup.id, dropoffStopRef: dropoff.id)]
        draft.fieldValues = [fieldRef: "Заказ 4417"]
        draft.revealedFieldRefs = [fieldRef, revealedOnly]
        return draft
    }

    @Test("A saved draft reads back whole — route, parcel, options, fields")
    func roundTrip() throws {
        let database = makeDatabase()
        let draft = fullDraft()
        try database.saveDraft(draft)

        let restored = try #require(try database.currentDraft())
        #expect(restored.id == draft.id)
        #expect(restored.createdAt == draft.createdAt)
        #expect(restored.proCourier && !restored.toDoor && restored.thermobag)
        #expect(restored.loaders == 2)
        #expect(restored.due == draft.due)
        #expect(restored.comment == "Домофон не работает")
        #expect(restored.chosenTariff == "cargo")

        // Array order is the position: pickup, drop-off, then the hole.
        #expect(restored.stops.map(\.role) == ["pickup", "dropoff", "dropoff"])
        #expect(restored.stops.map(\.id) == draft.stops.map(\.id))
        let first = try #require(restored.stops[0].point)
        #expect(first.latitude == 55.7558)
        #expect(first.address == "Москва, Тверская 1")
        #expect(first.addressParts?.entrance == "2")
        #expect(first.contactGivenName == "Иван")
        #expect(first.contactPhoneExtension == "12")
        #expect(restored.stops[2].point == nil)

        let item = try #require(restored.items.only)
        #expect(item.quantity == 2 && item.weightKg == 3.5 && item.cost == "2500.00")
        #expect(item.currency == "RUB")
        #expect(item.pickupStopRef == draft.stops[0].id)
        #expect(item.dropoffStopRef == draft.stops[1].id)

        #expect(restored.fieldValues == draft.fieldValues)
        #expect(restored.revealedFieldRefs == draft.revealedFieldRefs)
    }

    @Test("Re-saving replaces children wholesale — a deleted stop leaves no row")
    func rewriteReplacesChildren() throws {
        let database = makeDatabase()
        var draft = fullDraft()
        try database.saveDraft(draft)

        // The sender deletes the drop-off and the item mid-edit.
        draft.stops = [draft.stops[0]]
        draft.items = []
        draft.fieldValues = [:]
        draft.revealedFieldRefs = []
        draft.comment = "edited"
        try database.saveDraft(draft)

        let restored = try #require(try database.currentDraft())
        #expect(restored.id == draft.id)
        #expect(restored.stops.map(\.id) == [draft.stops[0].id])
        #expect(restored.items.isEmpty)
        #expect(restored.fieldValues.isEmpty && restored.revealedFieldRefs.isEmpty)
        #expect(restored.comment == "edited")
        // The projection alone can't prove the rows died — count the tables.
        let childRows = try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM "draftStops")
                     + (SELECT COUNT(*) FROM "draftItems")
                     + (SELECT COUNT(*) FROM "draftCustomFields")
                """) ?? 0
        }
        #expect(childRows == 1)  // the surviving stop, nothing else
    }

    @Test("One draft ever — a second id's save collapses the first")
    func singletonCollapse() throws {
        let database = makeDatabase()
        try database.saveDraft(fullDraft())
        var other = OrderDraft(createdAt: .now)
        other.comment = "newer"
        try database.saveDraft(other)

        let restored = try #require(try database.currentDraft())
        #expect(restored.id == other.id)
        #expect(restored.comment == "newer")
        let count = try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"orderDrafts\"") ?? 0
        }
        #expect(count == 1)
    }

    @Test("An absent draft reads nil; a consumed draft deletes its children too")
    func deleteCascades() throws {
        let database = makeDatabase()
        #expect(try database.currentDraft() == nil)

        try database.saveDraft(fullDraft())
        try database.deleteDrafts()
        #expect(try database.currentDraft() == nil)
        let orphans = try database.queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM "draftStops")
                     + (SELECT COUNT(*) FROM "draftItems")
                     + (SELECT COUNT(*) FROM "draftCustomFields")
                """) ?? 0
        }
        #expect(orphans == 0)
    }

    @Test("An unreadable draft row does not pose as empty")
    func corruptRowReadsAsUnreadable() throws {
        let database = makeDatabase()
        // A STRICT TEXT PRIMARY KEY column holding garbage fails the UUID decode —
        // currentDraft must throw rather than answer "no draft" over live bytes.
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO "orderDrafts"
                  ("id", "createdAt", "proCourier", "toDoor", "thermobag",
                   "loaders", "comment")
                VALUES ('not-a-uuid', 0, 0, 1, 0, 0, '')
                """)
        }
        #expect(throws: (any Error).self) { try database.currentDraft() }
    }
}

private extension Collection {
    /// The one element, or nil — order matters less than there being exactly one.
    var only: Element? { count == 1 ? first : nil }
}

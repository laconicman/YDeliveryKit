import Foundation
import GRDB
import Testing
import YDeliveryKit
@testable import YDeliveryData

/// Record integrity (doc:Collaboration → "Provider state is signed by the
/// device that wrote it"): owner rows sign at write, verify at read, and a
/// signature failure renders as a verdict — never a refusal, never a dropped
/// row. Each test runs its own store and its own Keychain service so keys
/// never leak across cases.
@Suite("Record signing")
struct RecordSigningTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecordSigningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A store with signing on. The test host has no keychain entitlement at
    /// all — `SecItemAdd` answers `errSecMissingEntitlement` for local and
    /// synchronizable items alike — so a keypair is injected straight into the
    /// resolved-key cell, one fresh signatory per store. What is exercised here
    /// is everything downstream of custody: stamping, signing, verification,
    /// pinning. The `SigningKeyStore` itself is device-verified only.
    private func makeSignedDatabase(signatory: Signatory = Signatory()) -> AppDatabase {
        let database = AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test",
            signingService: "test.signing.\(UUID().uuidString)")
        database.signingKeyCell.withLock { $0 = .some(.some(signatory)) }
        return database
    }

    /// Signing off entirely — what previews and keychain-less hosts run.
    private func makeDatabase() -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test")
    }

    private func order() -> Order {
        Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55.75, longitude: 37.61, address: "Тверская, 6")],
            price: "850.00", currency: "RUB", claimID: "claim-sign-1")
    }

    // MARK: The happy path — write signs, read verifies

    @Test("A recorded order reads back verified — mirror and stops alike")
    func recordedOrderVerifies() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())

        let stored = try #require(database.readOrders().first)
        #expect(stored.signatureStatus == .verified)
        #expect(stored.route.first?.signatureStatus == .verified)
    }

    @Test("A provider event signs at insert and verifies at read")
    func recordedEventVerifies() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        let event = ProviderEvent(
            orderID: try #require(database.readOrders().first).id, at: .now,
            kind: "status", providerStatus: "accepted", source: "journal")
        try database.recordProviderEvent(event)

        let events = try database.providerEvents(orderID: event.orderID)
        #expect(events.first?.signatureStatus == .verified)
    }

    // MARK: Forgery shapes — each lands a warning verdict, not a crash

    @Test("A column rewritten out of band reads .invalid")
    func tamperedMirrorIsInvalid() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())

        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderProviderStates" SET "price" = '1.00'
                """)
        }
        #expect(try database.readOrders().first?.signatureStatus == .invalid,
                "the signature covers persisted bytes — a raw edit breaks it")
    }

    @Test("A rewritten stop address reads .invalid on the point")
    func tamperedStopIsInvalid() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())

        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "routeStops" SET "address" = 'Подделанный адрес'
                """)
        }
        let stored = try #require(database.readOrders().first)
        #expect(stored.route.first?.signatureStatus == .invalid,
                "the whole row is signed — address forgery fails like a faked visit")
        #expect(stored.signatureStatus == .verified,
                "the mirror itself is untouched and stays verified")
    }

    @Test("A signature stripped out of band reads .unsigned on a signing order")
    func strippedSignatureIsUnsigned() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        let event = ProviderEvent(
            orderID: try #require(database.readOrders().first).id, at: .now,
            kind: "status", providerStatus: "accepted", source: "journal")
        try database.recordProviderEvent(event)

        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "providerEvents" SET "signature" = NULL
                """)
        }
        #expect(try database.providerEvents(orderID: event.orderID)
            .first?.signatureStatus == .unsigned,
                "signing is active on this order — unsigned means the write bypassed the owner")
    }

    @Test("A store without key custody reads .notSigned — quiet, not forged")
    func unsignedStoreReadsNotSigned() throws {
        let database = makeDatabase()
        try database.recordOrder(order())

        let stored = try #require(database.readOrders().first)
        #expect(stored.signatureStatus == .notSigned)
        #expect(stored.route.first?.signatureStatus == .notSigned)
    }

    // MARK: TOFU — first sight trusts, a changed key warns

    @Test("A changed owner key reads .keyChanged and the pin does not follow")
    func changedKeyIsFlagged() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        #expect(try database.readOrders().first?.signatureStatus == .verified,
                "first sight pins the key")
        let originalKey: String? = try database.queue.read {
            try String.fetchOne($0, sql: "SELECT \"ownerSigningKey\" FROM \"orders\"")
        }

        let foreign = Signatory().publicKey.base64EncodedString()
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orders" SET "ownerSigningKey" = ?
                """, arguments: [foreign])
        }
        let stored = try #require(database.readOrders().first)
        #expect(stored.signatureStatus == .keyChanged)
        let pinned: String? = try database.queue.read {
            try String.fetchOne($0, sql: "SELECT \"publicKey\" FROM \"ownerKeyPins\"")
        }
        #expect(pinned == originalKey,
                "a silent re-pin would bless the change it exists to catch")
    }

    // MARK: The legacy boundary — pre-signing rows sign on first contact

    @Test("A migrated order signs at import — owner history is not flagged")
    func migratedOrderSigns() throws {
        let database = makeSignedDatabase()
        let signatory = Signatory()
        try database.queue.write { db in
            try AppDatabase.insertMigrating(
                order(), provider: "yandex", signatory: signatory, into: db)
        }

        let stored = try #require(database.readOrders().first)
        #expect(stored.signatureStatus == .verified)
        #expect(stored.route.first?.signatureStatus == .verified)
    }

    @Test("An unsigned-then-rewritten order regains signatures wholesale")
    func stampBackfillsChildren() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        let orderID = try #require(database.readOrders().first).id
        try database.recordProviderEvent(ProviderEvent(
            orderID: orderID, at: .now, kind: "status",
            providerStatus: "accepted", source: "journal"))

        // Simulate the pre-signing world: key and signatures stripped, as if
        // written before the columns existed.
        try database.queue.write { db in
            try db.execute(sql: "UPDATE \"orders\" SET \"ownerSigningKey\" = NULL")
            try db.execute(sql: "UPDATE \"orderProviderStates\" SET \"signature\" = NULL")
            try db.execute(sql: "UPDATE \"routeStops\" SET \"signature\" = NULL")
            try db.execute(sql: "UPDATE \"providerEvents\" SET \"signature\" = NULL")
        }
        #expect(try database.readOrders().first?.signatureStatus == .notSigned)

        var updated = order()
        updated.id = orderID
        updated.price = "900.00"
        try database.recordOrder(updated)

        let stored = try #require(database.readOrders().first)
        #expect(stored.signatureStatus == .verified,
                "stamping the key backfills every unsigned child")
        #expect(stored.route.first?.signatureStatus == .verified)
        #expect(try database.providerEvents(orderID: orderID)
            .allSatisfy { $0.signatureStatus == .verified })
    }

    // MARK: Primitives

    @Test("Ed25519 verifies its own signature — and a foreign key does not")
    func signingRoundTrips() throws {
        let signatory = Signatory()
        let payload = Data("same row bytes".utf8)
        let signature = try signatory.sign(payload)
        #expect(Signatory.verify(
            payload: payload, signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: signatory.publicKey.base64EncodedString()))
        #expect(!Signatory.verify(
            payload: payload, signatureBase64: signature.base64EncodedString(),
            publicKeyBase64: Signatory().publicKey.base64EncodedString()))
        #expect(signatory.keyID.hasPrefix("ed25519.v1."))
    }

    @Test("A store with an unavailable key store writes unsigned, not forged")
    func keyStoreFailureWritesUnsigned() throws {
        // The host's keychain refusal is the real-world path here: custody
        // failed, writes still land, and reads answer .notSigned — the store
        // could not have signed, so nothing is flagged.
        let database = AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test",
            signingService: "test.signing.\(UUID().uuidString)")
        try database.recordOrder(order())
        #expect(try database.readOrders().first?.signatureStatus == .notSigned)
    }

    @Test("The canonical payload is byte-stable and column-sensitive")
    func payloadIsCanonical() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        try database.queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT * FROM "orderProviderStates"
                """))
            let a = CanonicalPayload.payload(
                table: "orderProviderStates",
                columns: CanonicalPayload.providerStateColumns, row: row)
            let b = CanonicalPayload.payload(
                table: "orderProviderStates",
                columns: CanonicalPayload.providerStateColumns, row: row)
            #expect(a == b)
            let shuffled = CanonicalPayload.payload(
                table: "orderProviderStates",
                columns: CanonicalPayload.providerStateColumns.reversed(), row: row)
            #expect(a != shuffled, "column order is part of the signed bytes")
        }
    }

    // MARK: Attribution — best-effort reads that never throw

    @Test("Authorship on an unsynced store reads empty, never fails")
    func authorshipDegradesQuietly() throws {
        let database = makeSignedDatabase()
        try database.recordOrder(order())
        let orderID = try #require(database.readOrders().first).id
        try database.recordProviderEvent(ProviderEvent(
            orderID: orderID, at: .now, kind: "status",
            providerStatus: "accepted", source: "journal"))

        let mirror = database.providerStateAuthorship(orderID: orderID)
        #expect(mirror.modifierRecordName == nil)
        let events = database.providerEventsAuthorship(orderID: orderID)
        #expect(events.count == 1, "one entry per stored event row")
        #expect(events.values.first?.modifierRecordName == nil,
                "no server record yet — attribution is absent, not fabricated")
    }
}

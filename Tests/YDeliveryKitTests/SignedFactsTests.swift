import Foundation
import GRDB
import Testing
import YDeliveryKit
@testable import YDeliveryData

/// Signed facts and the verdicts at read (the app's Collaboration → "Sign facts,
/// derive state", "Verdicts and entitlement"; Schema → "Derived integrity"). The
/// authority is the fake from the key-row tests, playing CloudKit's stamps; this
/// device signs with an ephemeral key, a second "device" with another one in the
/// same store.
@Suite("Signed facts and verdicts")
struct SignedFactsTests {
    private let directory: URL
    private static let container = "iCloud.test"

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SignedFactsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase(keyStore: any SigningKeyStore = EphemeralKeyStore()) -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: Self.container, keyStore: keyStore)
    }

    private func party(_ subject: String) -> UUID {
        UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: subject)
    }

    private var me: UUID { party("_me") }

    /// A private order on this device: the authority answers `.local`.
    private func privateAuthority(_ database: AppDatabase) throws -> TrustRowsTests.FakeAuthority {
        TrustRowsTests.FakeAuthority(localParty: me, owner: nil, myKeyID: try database.signatory().keyID)
    }

    private func recordOrder(in database: AppDatabase) throws -> Order {
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55.75, longitude: 37.61, address: "Тверская, 6"),
                    RoutePoint(latitude: 55.76, longitude: 37.59, address: "Арбат, 1")],
            claimID: "claim-\(UUID().uuidString.prefix(8))")
        try database.recordOrder(order, providerObservedAt: Date(timeIntervalSince1970: 1_000))
        return order
    }

    private func journal(_ status: String, id: Int64, at: TimeInterval, orderID: UUID, revision: Int64 = 1,
                         detail: String? = nil) -> OrderEvent {
        OrderEvent(orderID: orderID, providerEventID: id, providerRevision: revision,
                   at: Date(timeIntervalSince1970: at), kind: OrderEvent.Kind.statusChanged,
                   providerStatus: status, detail: detail, source: OrderEvent.Source.journal)
    }

    private func sighting(_ status: String, revision: Int64, at: TimeInterval, orderID: UUID,
                          digest: String? = nil) -> OrderEvent {
        OrderEvent(orderID: orderID, providerRevision: revision, at: Date(timeIntervalSince1970: at),
                   kind: OrderEvent.Kind.sighting, providerStatus: status, source: OrderEvent.Source.card,
                   routeDigest: digest)
    }

    // MARK: Verdicts on events

    @Test("A recorded event is signed under this device's key, carries the key in its id, and verifies as the owner's")
    func recordedEventVerifies() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let event = journal("accepted", id: 1, at: 1_100, orderID: order.id)
        #expect(try database.recordEvent(event).inserted)
        let stored = try database.events(orderID: order.id)
        #expect(stored.count == 1)
        #expect(stored[0].id != event.id, "the derived id carries the writer's key (rule 1)")
        #expect(stored[0].id == OrderEvent.derivedID(
            orderID: order.id, providerEventID: 1, providerRevision: 1, providerStatus: "accepted",
            routeDigest: nil, writerKeyID: try database.signatory().keyID))
        #expect(try database.participantKeys(orderID: order.id).count == 1, "the key is published with the first write")
        let attested = try database.attestedEvents(orderID: order.id, authority: try privateAuthority(database))
        #expect(attested.count == 1)
        #expect(attested[0].verdict == .verified(author: Party(ref: me, role: .owner)))
        #expect(attested[0].value == stored[0])
    }

    @Test("A replayed insert changes nothing and signs nothing; a caller-held id is kept")
    func replayIsANoOp() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let event = journal("accepted", id: 1, at: 1_100, orderID: order.id)
        try database.recordEvent(event)
        #expect(!(try database.recordEvent(event).inserted))
        #expect(try database.events(orderID: order.id).count == 1)
        #expect(try database.participantKeys(orderID: order.id).count == 1)
        let held = UUID()
        var custom = journal("pickuped", id: 2, at: 1_200, orderID: order.id)
        custom.id = held
        try database.recordEvent(custom)
        #expect(try database.events(orderID: order.id).contains { $0.id == held }, "a caller-held id stays the caller's")
    }

    @Test("Tampered, stripped, pre-signing and unknown-key rows read invalid, unsigned, legacy and untrustedKey")
    func theWarnedVerdicts() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id, detail: "ok"))
        try database.recordEvent(journal("pickuped", id: 2, at: 1_200, orderID: order.id))
        try database.recordEvent(journal("delivered", id: 3, at: 1_300, orderID: order.id))
        let ids = try database.events(orderID: order.id).map(\.id)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderEvents" SET "detail" = 'rewritten' WHERE "id" = ?
                """, arguments: AppDatabase.args([ids[0]]))
            try db.execute(sql: """
                UPDATE "orderEvents" SET "signature" = NULL, "signingKeyID" = NULL WHERE "id" = ?
                """, arguments: AppDatabase.args([ids[1]]))
            try db.execute(sql: """
                UPDATE "orderEvents" SET "signingKeyID" = 'p256.v2.deadbeefdeadbeef' WHERE "id" = ?
                """, arguments: AppDatabase.args([ids[2]]))
        }
        let verdicts = try database.attestedEvents(orderID: order.id, authority: authority).map(\.verdict)
        #expect(verdicts == [.invalid, .unsigned, .untrustedKey])

        // A pre-signing order: NULL pairs and no key rows at all.
        let legacyOrder = try recordOrder(in: database)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO "orderEvents" ("id", "orderID", "at", "kind", "providerStatus", "source")
                VALUES (?, ?, 1100, 'status_changed', 'accepted', 'journal')
                """, arguments: AppDatabase.args([UUID(), legacyOrder.id]))
        }
        let legacy = try database.attestedEvents(orderID: legacyOrder.id, authority: authority)
        #expect(legacy.map(\.verdict) == [.legacy], "quiet: history from before signing existed")
    }

    @Test("A member's correctly signed order event reads notEntitled; their message reads verified")
    func memberEntitlement() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina")
        // Irina's device: her own key, writing into the same store.
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        var forged = journal("delivered", id: 9, at: 1_900, orderID: order.id)
        forged.authorRef = irina
        try irinaDevice.recordEvent(forged)
        try irinaDevice.postMessage(OrderMessage(orderID: order.id, kind: OrderMessage.Kind.text,
                                                 text: "у ворот", authorRef: irina))
        let irinaKey = try irinaDevice.signatory().keyID
        let authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: me, participants: [Member(ref: irina, canWrite: true, displayName: "Ирина")],
            stamps: [irinaKey: irina], myKeyID: try owner.signatory().keyID)
        let events = try owner.attestedEvents(orderID: order.id, authority: authority)
        #expect(events.count == 1)
        #expect(events[0].verdict == .notEntitled(
            author: Party(ref: irina, displayName: "Ирина", role: .member(kind: Membership.Role.participant))),
            "a correctly signed row by a party who may not write it, named")
        let messages = try owner.attestedMessages(orderID: order.id, authority: authority)
        #expect(messages.count == 1 && messages[0].verdict.isVerified, "the chat is every member's")
        #expect(messages[0].verdict.author?.displayName == "Ирина")
        // A row claiming another author than its key's party is a rewrite.
        try owner.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderMessages" SET "authorRef" = ? WHERE "orderID" = ?
                """, arguments: AppDatabase.args([me, order.id]))
        }
        #expect(try owner.attestedMessages(orderID: order.id, authority: authority)[0].verdict == .invalid)
    }

    /// A store that fails once, then yields a key.
    final class OnceFailingKeyStore: SigningKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        private let key = Signatory.ephemeral()
        func signatory() throws -> Signatory {
            lock.lock(); defer { lock.unlock() }
            guard failed else {
                failed = true
                throw KeyCustodyError(operation: .read, status: errSecInteractionNotAllowed)
            }
            return key
        }
    }

    @Test("Custody failing for one write leaves that row unsigned and the next row signed")
    func custodyFailureIsOneRow() throws {
        let database = makeDatabase(keyStore: OnceFailingKeyStore())
        let order = try recordOrder(in: database)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id))
        try database.recordEvent(journal("pickuped", id: 2, at: 1_200, orderID: order.id))
        let authority = TrustRowsTests.FakeAuthority(localParty: me, owner: nil, myKeyID: try database.signatory().keyID)
        let verdicts = try database.attestedEvents(orderID: order.id, authority: authority).map(\.verdict)
        #expect(verdicts == [.unsigned, .verified(author: Party(ref: me, role: .owner))])
    }

    @Test("A key not yet bound, on another device's row, reads unverifiable")
    func unboundForeignKeyIsUnverifiable() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let other = makeDatabase(keyStore: EphemeralKeyStore())
        try other.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id))
        let authority = TrustRowsTests.FakeAuthority(localParty: me, owner: me, myKeyID: try owner.signatory().keyID)
        #expect(try owner.attestedEvents(orderID: order.id, authority: authority).map(\.verdict) == [.unverifiable])
    }

    // MARK: Attachments

    @Test("A photo verifies with its hash; a blob swapped under the same id reads invalid")
    func photoVerifiesAndSwappedBlobIsInvalid() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let posted = try database.postPhotoMessage(orderID: order.id, data: Data([0x89, 0x50, 0x4E, 0x47]))
        let attachmentID = try #require(posted.attachmentRef)
        let attested = try #require(try database.attestedAttachment(attachmentID, authority: authority))
        #expect(attested.verdict.isVerified && attested.value.dataHash == AppDatabase.dataHash(of: Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(try database.attestedMessages(orderID: order.id, authority: authority)[0].verdict.isVerified)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "attachmentBlobs" SET "data" = ? WHERE "attachmentID" = ?
                """, arguments: AppDatabase.args([Data([0x00]), attachmentID]))
        }
        #expect(try database.attestedAttachment(attachmentID, authority: authority)?.verdict == .invalid,
                "the row claims bytes it does not hold")
        #expect(try database.attestedAttachment(UUID(), authority: authority) == nil)
    }

    // MARK: Derived integrity

    @Test("The mirror agrees with the latest verified event, disagrees when rewritten, and recovers on a newer event")
    func mirrorIntegrity() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .noSignedHistory)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id))
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderProviderStates" SET "providerStatus" = 'delivered' WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: "accepted"))
        try database.recordEvent(journal("pickuped", id: 2, at: 1_200, orderID: order.id))
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent)
    }

    @Test("The total order: a later stamp wins, a journal row beats a card at one stamp, a higher revision within a family")
    func totalOrder() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id, revision: 1))
        try database.recordEvent(sighting("estimating", revision: 9, at: 1_050, orderID: order.id))
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent,
                "a later stamp wins regardless of revision")
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderProviderStates" SET "providerStatus" = 'estimating' WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: "accepted"),
                "a rollback to an older status reads disagrees: one expected value, never a set")
        // At one stamp, the journal beats a card.
        try database.recordEvent(sighting("ready_for_approval", revision: 2, at: 1_100, orderID: order.id))
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: "accepted"))
        // Within one family, the higher revision wins.
        try database.recordEvent(sighting("pickuped", revision: 3, at: 1_300, orderID: order.id))
        try database.recordEvent(sighting("accepted", revision: 2, at: 1_300, orderID: order.id))
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: "pickuped"))
    }

    @Test("The route agrees with the latest signed digest, disagrees when a stop is rewritten, and recovers on a fresh sighting")
    func routeIntegrity() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        #expect(try database.routeIntegrity(orderID: order.id, authority: authority) == .noSignedHistory)
        let digest = CanonicalPayload.routeDigest(for: order.route)
        #expect(try database.storedRouteDigest(orderID: order.id) == digest)
        try database.recordEvent(sighting("accepted", revision: 1, at: 1_100, orderID: order.id, digest: digest))
        #expect(try database.routeIntegrity(orderID: order.id, authority: authority) == .consistent)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "routeStops" SET "address" = 'Тверская, 7' WHERE "orderID" = ? AND "position" = 0
                """, arguments: AppDatabase.args([order.id]))
        }
        #expect(try database.routeIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: digest))
        // A corrected route under an unchanged status is a fresh sighting, not a dropped one.
        let corrected = try database.storedRouteDigest(orderID: order.id)
        #expect(try database.recordEvent(sighting("accepted", revision: 2, at: 1_200, orderID: order.id, digest: corrected)).inserted)
        #expect(try database.routeIntegrity(orderID: order.id, authority: authority) == .consistent)
    }

    // MARK: Dedupe by fact

    @Test("Two writers' rows for one fact collapse to one entry; twins that disagree stay apart")
    func dedupeByFact() throws {
        let phone = makeDatabase()
        let tablet = makeDatabase(keyStore: EphemeralKeyStore())
        let order = try recordOrder(in: phone)
        let event = journal("accepted", id: 1, at: 1_100, orderID: order.id, detail: "ok")
        try phone.recordEvent(event)
        try tablet.recordEvent(event)
        #expect(try phone.events(orderID: order.id).count == 2, "two rows, never one merged record")
        let authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: nil,
            stamps: [try phone.signatory().keyID: me, try tablet.signatory().keyID: me],
            myKeyID: try phone.signatory().keyID)
        let folded = try phone.attestedEvents(orderID: order.id, authority: authority)
        #expect(folded.count == 1 && folded[0].verdict.isVerified, "one fact, one entry")
        var twin = journal("accepted", id: 1, at: 1_100, orderID: order.id, detail: "rewritten")
        twin.id = UUID()
        try tablet.recordEvent(twin)
        let apart = try phone.attestedEvents(orderID: order.id, authority: authority)
        #expect(apart.count == 2, "a twin that disagrees on a fact column stays apart with its own verdict")
        // Verified wins the representative role over an unverifiable twin of the same fact.
        let stranger = makeDatabase(keyStore: EphemeralKeyStore())
        try stranger.recordEvent(event)
        let withStranger = try phone.attestedEvents(orderID: order.id, authority: authority)
        #expect(withStranger.count == 3, "an unresolvable row folds with nothing")
        #expect(withStranger.contains { $0.verdict == .unverifiable })
    }

    @Test("Models carry no verdict in their Codable output")
    func modelsHaveNoVerdictKey() throws {
        let order = UUID()
        let event = journal("accepted", id: 1, at: 1_100, orderID: order)
        let message = OrderMessage(orderID: order, kind: OrderMessage.Kind.text, text: "hi")
        for data in [try JSONEncoder().encode(event), try JSONEncoder().encode(message)] {
            let json = String(decoding: data, as: UTF8.self)
            #expect(!json.contains("verdict") && !json.contains("signature"))
        }
    }
}

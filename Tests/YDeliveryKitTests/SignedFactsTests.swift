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
            routeDigest: nil, at: event.at, writerKeyID: try database.signatory().keyID))
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

    @Test("A photo posted with an author names that party on both rows and its key row; the default names nobody")
    func photoCarriesItsAuthor() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina")
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        let posted = try irinaDevice.postPhotoMessage(orderID: order.id, data: Data([1, 2, 3]), authorRef: irina)
        let attachmentID = try #require(posted.attachmentRef)
        #expect(posted.authorRef == irina)
        let irinaKey = try irinaDevice.signatory().keyID
        #expect(try owner.participantKeys(orderID: order.id).first { $0.keyID == irinaKey }?.partyRef == irina,
                "the post published Irina's key under her party")
        let authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: me, participants: [Member(ref: irina, canWrite: true, displayName: "Ирина")],
            stamps: [irinaKey: irina], myKeyID: try owner.signatory().keyID)
        let attachment = try #require(try owner.attestedAttachment(attachmentID, authority: authority))
        #expect(attachment.value.authorRef == irina && attachment.verdict.isVerified)
        #expect(attachment.verdict.author?.ref == irina && attachment.verdict.author?.displayName == "Ирина")
        let message = try #require(try owner.attestedMessages(orderID: order.id, authority: authority).first)
        #expect(message.value.authorRef == irina && message.verdict.author?.ref == irina)

        // The default is today's post: no author on either row, still verified as this device's.
        let database = makeDatabase()
        let other = try recordOrder(in: database)
        let unattributed = try database.postPhotoMessage(orderID: other.id, data: Data([4, 5]))
        let localAuthority = try privateAuthority(database)
        let unattributedID = try #require(unattributed.attachmentRef)
        let row = try #require(try database.attestedAttachment(unattributedID, authority: localAuthority))
        #expect(unattributed.authorRef == nil && row.value.authorRef == nil && row.verdict.isVerified)
        #expect(try database.participantKeys(orderID: other.id).map(\.partyRef) == [nil])
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
        // Within one family, the higher revision wins — and the mirror follows the
        // same order at an equal stamp, whatever arrives last.
        try database.recordEvent(sighting("pickuped", revision: 3, at: 1_300, orderID: order.id))
        try database.recordEvent(sighting("accepted", revision: 2, at: 1_300, orderID: order.id))
        #expect(try database.readOrders().first?.providerStatus == "pickuped")
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderProviderStates" SET "providerStatus" = 'accepted' WHERE "orderID" = ?
                """, arguments: AppDatabase.args([order.id]))
        }
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .disagrees(expected: "pickuped"))
        // Within the journal family, two transitions in one second are feed order.
        let feed = try recordOrder(in: database)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: feed.id))
        #expect(try database.recordEvent(journal("performer_found", id: 2, at: 1_100, orderID: feed.id)).statusAdvanced)
        #expect(try database.readOrders().first { $0.id == feed.id }?.providerStatus == "performer_found")
        #expect(try database.mirrorIntegrity(orderID: feed.id, authority: authority) == .consistent)
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

    @Test("A signed replay of a fact already recorded unsigned adds no row and is no news")
    func keylessReplayAddsNoRow() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let event = journal("accepted", id: 42, at: 1_100, orderID: order.id)
        // Imported history: the keyless id, no signature, no key rows.
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO "orderEvents" ("id", "orderID", "providerEventID", "providerRevision", "at", "kind", "providerStatus", "source")
                VALUES (?, ?, 42, 1, 1100, 'status_changed', 'accepted', 'journal')
                """, arguments: AppDatabase.args([event.id, order.id]))
        }
        let replay = try database.recordEvent(event)
        #expect(!replay.inserted, "no second row for the same fact")
        #expect(try database.events(orderID: order.id).count == 1)
        #expect(try database.attestedEvents(orderID: order.id, authority: authority).map(\.verdict) == [.legacy],
                "the old row stays as it is, never re-signed")
    }

    @Test("A revisionless status that returns later is a fresh signed row, and the mirror agrees with it")
    func revisionlessReturnIsAFreshRow() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        func revisionless(_ status: String, at: TimeInterval) -> OrderEvent {
            OrderEvent(orderID: order.id, at: Date(timeIntervalSince1970: at), kind: OrderEvent.Kind.sighting,
                       providerStatus: status, source: OrderEvent.Source.card)
        }
        try database.recordEvent(revisionless("accepted", at: 1_100))
        try database.recordEvent(journal("pickuped", id: 2, at: 1_200, orderID: order.id))
        #expect(try database.recordEvent(revisionless("accepted", at: 1_300)).inserted)
        #expect(!(try database.recordEvent(revisionless("accepted", at: 1_300)).inserted), "a re-sight of one card state is a no-op")
        #expect(try database.events(orderID: order.id).count == 3)
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent)
    }

    @Test("At one stamp the mirror follows the total order, not arrival: a card after a journal row does not move it")
    func equalStampMirrorFollowsTheOrder() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: order.id))
        let card = try database.recordEvent(sighting("pickuped", revision: 2, at: 1_100, orderID: order.id))
        #expect(card.inserted && !card.statusAdvanced, "recorded, outranked at this stamp")
        #expect(try database.readOrders().first?.providerStatus == "accepted")
        #expect(try database.mirrorIntegrity(orderID: order.id, authority: authority) == .consistent)
        // The journal row arriving second at the same stamp takes the mirror.
        let other = try recordOrder(in: database)
        try database.recordEvent(sighting("pickuped", revision: 2, at: 1_100, orderID: other.id))
        #expect(try database.recordEvent(journal("accepted", id: 1, at: 1_100, orderID: other.id)).statusAdvanced)
        #expect(try database.readOrders().first { $0.id == other.id }?.providerStatus == "accepted")
        #expect(try database.mirrorIntegrity(orderID: other.id, authority: authority) == .consistent)
    }

    @Test("A read-only participant is a reader: their signed message reads notEntitled")
    func readOnlyMemberIsNotEntitled() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let reader = party("_reader")
        let readerDevice = makeDatabase(keyStore: EphemeralKeyStore())
        try readerDevice.postMessage(OrderMessage(orderID: order.id, kind: OrderMessage.Kind.text, text: "hi", authorRef: reader))
        let authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: me, participants: [Member(ref: reader, canWrite: false)],
            stamps: [try readerDevice.signatory().keyID: reader], myKeyID: try owner.signatory().keyID)
        let verdict = try owner.attestedMessages(orderID: order.id, authority: authority)[0].verdict
        #expect(verdict == .notEntitled(author: Party(ref: reader, role: .member(kind: Membership.Role.reader))))
    }

    @Test("A permission the share changed is undated until the owner's device mirrors it; then each row is judged as of its stamp")
    func permissionChangeIsDated() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina")
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        let irinaKey = try irinaDevice.signatory().keyID
        func authority(canWrite: Bool) throws -> TrustRowsTests.FakeAuthority {
            TrustRowsTests.FakeAuthority(
                localParty: me, owner: me, participants: [Member(ref: irina, canWrite: canWrite)],
                stamps: [irinaKey: irina], myKeyID: try owner.signatory().keyID)
        }
        func post(_ text: String, at: TimeInterval) throws {
            try irinaDevice.postMessage(OrderMessage(orderID: order.id, sentAt: Date(timeIntervalSince1970: at),
                                                     kind: OrderMessage.Kind.text, text: text, authorRef: irina))
        }
        func verdicts(_ authority: TrustRowsTests.FakeAuthority) throws -> [Verdict] {
            try owner.attestedMessages(orderID: order.id, authority: authority).map(\.verdict)
        }
        let writer = try authority(canWrite: true), reader = try authority(canWrite: false)
        try owner.reconcileMemberships(orderID: order.id, authority: writer, at: Date(timeIntervalSince1970: 1_050))
        try post("as a writer", at: 1_100)
        #expect(try verdicts(writer)[0].isVerified)
        // The share makes her read-only; nothing dates it yet.
        #expect(try verdicts(reader) == [.unverifiable], "an undated downgrade places nobody")
        try owner.reconcileMemberships(orderID: order.id, authority: reader, at: Date(timeIntervalSince1970: 1_200))
        try post("as a reader", at: 1_300)
        #expect(try verdicts(reader) == [
            .verified(author: Party(ref: irina, role: .member(kind: Membership.Role.participant))),
            .notEntitled(author: Party(ref: irina, role: .member(kind: Membership.Role.reader))),
        ], "what she wrote as a writer stays verified; what is dated after the downgrade is hers and not entitled")
        // Restored, undated, then dated.
        #expect(try verdicts(writer) == [.unverifiable, .unverifiable])
        try owner.reconcileMemberships(orderID: order.id, authority: writer, at: Date(timeIntervalSince1970: 1_400))
        try post("a writer again", at: 1_500)
        #expect(try verdicts(writer).map(\.isVerified) == [true, false, true])
    }

    @Test("No roster cached places nobody but the owner")
    func noRosterPlacesNobody() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina")
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        var authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: me, participants: [Member(ref: irina, canWrite: true)],
            stamps: [try irinaDevice.signatory().keyID: irina], myKeyID: try owner.signatory().keyID)
        try owner.reconcileMemberships(orderID: order.id, authority: authority, at: Date(timeIntervalSince1970: 1_050))
        try irinaDevice.postMessage(OrderMessage(orderID: order.id, kind: OrderMessage.Kind.text, text: "hi", authorRef: irina))
        try owner.postMessage(OrderMessage(orderID: order.id, kind: OrderMessage.Kind.text, text: "hello", authorRef: me))
        #expect(try owner.attestedMessages(orderID: order.id, authority: authority).allSatisfy(\.verdict.isVerified))
        authority.rosterUnavailable = true
        let verdicts = try owner.attestedMessages(orderID: order.id, authority: authority).map(\.verdict)
        #expect(verdicts.contains(.unverifiable) && verdicts.contains(.verified(author: Party(ref: me, role: .owner))),
                "her live row alone places nobody without the share; the owner is the owner by ownership")
    }

    @Test("A price-only row at the same stamp never blocks the status row, in either arrival order")
    func priceEventDoesNotBlockStatus() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        func price(id: Int64, orderID: UUID) -> OrderEvent {
            OrderEvent(orderID: orderID, providerEventID: id, providerRevision: 1, at: Date(timeIntervalSince1970: 1_100),
                       kind: OrderEvent.Kind.priceChanged, detail: "850 RUB", source: OrderEvent.Source.journal)
        }
        let first = try recordOrder(in: database)
        #expect(!(try database.recordEvent(price(id: 12, orderID: first.id)).statusAdvanced))
        #expect(try database.recordEvent(journal("accepted", id: 11, at: 1_100, orderID: first.id)).statusAdvanced,
                "a price row that outranks it by operation id never set the mirror")
        #expect(try database.readOrders().first { $0.id == first.id }?.providerStatus == "accepted")
        #expect(try database.mirrorIntegrity(orderID: first.id, authority: authority) == .consistent)
        let second = try recordOrder(in: database)
        #expect(try database.recordEvent(journal("accepted", id: 11, at: 1_100, orderID: second.id)).statusAdvanced)
        #expect(!(try database.recordEvent(price(id: 12, orderID: second.id)).statusAdvanced))
        #expect(try database.readOrders().first { $0.id == second.id }?.providerStatus == "accepted")
        #expect(try database.mirrorIntegrity(orderID: second.id, authority: authority) == .consistent)
    }

    @Test("A revisionless observation stored under its former id is recognised on replay; a later one is a new row")
    func formerRevisionlessIDIsRecognised() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        func revisionless(at: TimeInterval) -> OrderEvent {
            OrderEvent(orderID: order.id, at: Date(timeIntervalSince1970: at), kind: OrderEvent.Kind.sighting,
                       providerStatus: "accepted", source: OrderEvent.Source.card)
        }
        let stored = revisionless(at: 1_100)
        let former = try #require(stored.formerKeylessDerivedID)
        #expect(former != stored.keylessDerivedID)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO "orderEvents" ("id", "orderID", "at", "kind", "providerStatus", "source")
                VALUES (?, ?, 1100, 'sighting', 'accepted', 'card')
                """, arguments: AppDatabase.args([former, order.id]))
        }
        #expect(!(try database.recordEvent(stored).inserted), "the same observation under its former id")
        #expect(try database.events(orderID: order.id).count == 1)
        #expect(try database.recordEvent(revisionless(at: 1_300)).inserted, "a later observation is new")
        #expect(try database.events(orderID: order.id).count == 2)
        // The former id covered the status and the digest only: a caller-held event, or
        // another kind or detail at the same stamp and status, is another fact.
        var held = revisionless(at: 1_100)
        held.id = UUID()
        held.kind = OrderEvent.Kind.statusChanged
        held.detail = "by hand"
        #expect(try database.recordEvent(held).inserted, "a caller-held id is the caller's fact")
        var detailed = revisionless(at: 1_100)
        detailed.detail = "courier called"
        #expect(try database.recordEvent(detailed).inserted, "another detail is another observation")
        #expect(try database.events(orderID: order.id).count == 4)
    }

    @Test("A member the share no longer lists verifies nothing until the departure is dated; then what they wrote as a member comes back")
    func departedMemberUntilDated() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina")
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        let irinaKey = try irinaDevice.signatory().keyID
        func authority(listing: [Member]) throws -> TrustRowsTests.FakeAuthority {
            TrustRowsTests.FakeAuthority(localParty: me, owner: me, participants: listing,
                                         stamps: [irinaKey: irina], myKeyID: try owner.signatory().keyID)
        }
        func post(_ text: String, at: TimeInterval) throws {
            try irinaDevice.postMessage(OrderMessage(orderID: order.id, sentAt: Date(timeIntervalSince1970: at),
                                                     kind: OrderMessage.Kind.text, text: text, authorRef: irina))
        }
        let listed = try authority(listing: [Member(ref: irina, canWrite: true)])
        try owner.reconcileMemberships(orderID: order.id, authority: listed, at: Date(timeIntervalSince1970: 1_050))
        try post("while a member", at: 1_100)
        #expect(try owner.attestedMessages(orderID: order.id, authority: listed)[0].verdict.isVerified)
        // She leaves: the share no longer lists her and no row dates it yet.
        let gone = try authority(listing: [])
        #expect(try owner.attestedMessages(orderID: order.id, authority: gone)[0].verdict == .unverifiable,
                "an undated departure places nobody: nothing of hers verifies, quietly")
        // The owner's device dates it; a row stamped after is hers and not entitled.
        try owner.reconcileMemberships(orderID: order.id, authority: gone, at: Date(timeIntervalSince1970: 1_200))
        try post("after", at: 1_300)
        let verdicts = try owner.attestedMessages(orderID: order.id, authority: gone).map(\.verdict)
        #expect(verdicts == [
            .verified(author: Party(ref: irina, role: .member(kind: Membership.Role.participant))),
            .notEntitled(author: Party(ref: irina, role: .unknown)),
        ], "what she wrote as a member stays verified; what is dated after the removal is named and not entitled")
    }

    @Test("A photo whose bytes are not here yet reads unverifiable, not verified")
    func missingPhotoBytesAreUnverifiable() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let posted = try database.postPhotoMessage(orderID: order.id, data: Data([1, 2, 3]))
        let attachmentID = try #require(posted.attachmentRef)
        try database.queue.write { db in
            try db.execute(sql: """
                DELETE FROM "attachmentBlobs" WHERE "attachmentID" = ?
                """, arguments: AppDatabase.args([attachmentID]))
        }
        #expect(try database.attestedAttachment(attachmentID, authority: authority)?.verdict == .unverifiable)
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

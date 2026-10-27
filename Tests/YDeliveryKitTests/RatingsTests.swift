import Foundation
import GRDB
import Testing
@testable import YDeliveryData

/// Ratings as signed facts (the app's Vision → "Players, trust and reputation";
/// Collaboration → "Sign facts, derive state"): the writer signs what it binds, the
/// attested read keeps every row, and the effective read selects the latest per
/// (author, subject) while the rows that do not count stand beside it. The authority
/// is the fake from the key-row tests; a second "device" writes into the same store
/// with its own key.
@Suite("Ratings")
struct RatingsTests {
    private let directory: URL
    private static let container = "iCloud.test"
    private static let courierRun = OrderRating.Subject(kind: OrderRating.Subject.Kind.leg, ref: "leg-0",
                                                       label: "Пётр · Kia Rio")

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RatingsTests-\(UUID().uuidString)", isDirectory: true)
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
            created: .now, status: .done,
            route: [RoutePoint(latitude: 55.75, longitude: 37.61, address: "Тверская, 6"),
                    RoutePoint(latitude: 55.76, longitude: 37.59, address: "Арбат, 1")],
            claimID: "claim-\(UUID().uuidString.prefix(8))")
        try database.recordOrder(order, providerObservedAt: Date(timeIntervalSince1970: 1_000))
        return order
    }

    private func rating(
        _ score: Int, at: TimeInterval, orderID: UUID, id: UUID = UUID(),
        subject: OrderRating.Subject = courierRun, authorRef: UUID? = nil
    ) -> OrderRating {
        OrderRating(id: id, orderID: orderID, authorRef: authorRef ?? me, subject: subject, score: score,
                    at: Date(timeIntervalSince1970: at))
    }

    // MARK: Writer

    @Test("A posted rating reads back verified as the owner's, with the key published in the same write")
    func postedRatingVerifies() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let posted = OrderRating(orderID: order.id, authorRef: me, subject: Self.courierRun, score: 5,
                                 comment: "аккуратно", at: Date(timeIntervalSince1970: 2_000))
        try database.postRating(posted)
        #expect(try database.participantKeys(orderID: order.id).count == 1)
        let attested = try database.attestedRatings(orderID: order.id, authority: try privateAuthority(database))
        #expect(attested.count == 1)
        #expect(attested[0].value == posted)
        #expect(attested[0].verdict == .verified(author: Party(ref: me, role: .owner)))
    }

    @Test("A retry under the same id is one row; two equal ratings under two ids are two rows")
    func identityIsTheCallers() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let first = rating(4, at: 2_000, orderID: order.id)
        try database.postRating(first)
        try database.postRating(first)
        #expect(try database.attestedRatings(orderID: order.id, authority: authority).count == 1)
        // The same score, subject and stamp under another id: a second decision.
        let twin = rating(4, at: 2_000, orderID: order.id)
        try database.postRating(twin)
        let attested = try database.attestedRatings(orderID: order.id, authority: authority)
        #expect(attested.count == 2 && attested.allSatisfy(\.verdict.isVerified))
        // One author, one subject: one counts, the other is its history, the tie
        // settled by the smallest id.
        let effective = try database.effectiveRatings(orderID: order.id, authority: authority)
        #expect(effective.counted.count == 1 && effective.counted[0].history.count == 1)
        let smallest = [first.id, twin.id].min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        #expect(effective.counted[0].current.value.id == smallest)
    }

    @Test("A score outside 1...5 and a rating with no order refuse")
    func refusals() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        #expect(throws: AppDatabase.WriteError.scoreOutOfRange) {
            try database.postRating(rating(0, at: 2_000, orderID: order.id))
        }
        #expect(throws: AppDatabase.WriteError.scoreOutOfRange) {
            try database.postRating(rating(6, at: 2_000, orderID: order.id))
        }
        #expect(throws: AppDatabase.WriteError.ratingHasNoOrder) {
            try database.postRating(rating(5, at: 2_000, orderID: UUID()))
        }
        #expect(try database.attestedRatings(orderID: order.id, authority: try privateAuthority(database)).isEmpty)
    }

    @Test("Custody failing for one post writes that row's signature pair NULL; once the order has a key it reads unsigned")
    func custodyFailureIsUnsigned() throws {
        let database = makeDatabase(keyStore: SignedFactsTests.OnceFailingKeyStore())
        let order = try recordOrder(in: database)
        try database.postRating(rating(3, at: 2_000, orderID: order.id))
        let receiver = OrderRating.Subject(kind: OrderRating.Subject.Kind.party, ref: party("_irina").uuidString)
        try database.postRating(rating(4, at: 2_100, orderID: order.id, subject: receiver))
        let authority = try privateAuthority(database)
        let attested = try database.attestedRatings(orderID: order.id, authority: authority)
        #expect(attested.map(\.verdict) == [.unsigned, .verified(author: Party(ref: me, role: .owner))])
        let effective = try database.effectiveRatings(orderID: order.id, authority: authority)
        #expect(effective.counted.count == 1 && effective.notCounted.map(\.value.score) == [3])
    }

    @Test("A fresh rating lifts its order in the list without touching the stamp")
    func ratingLiftsOrderInReadOrder() throws {
        let database = makeDatabase()
        let older = try recordOrder(in: database)
        let newer = try recordOrder(in: database)
        try database.postMessage(OrderMessage(orderID: newer.id, sentAt: Date().addingTimeInterval(60),
                                              kind: OrderMessage.Kind.text, text: "у ворот"))
        #expect(try database.readOrders().first?.id == newer.id, "the newer chat leads before any rating")
        let stamp = {
            try database.queue.read { db in
                try Double.fetchOne(db, sql: """
                    SELECT "lastActivityAt" FROM "orders" WHERE "id" = ?
                    """, arguments: AppDatabase.args([older.id]))
            }
        }
        let before = try stamp()
        try database.postRating(OrderRating(orderID: older.id, authorRef: me, subject: Self.courierRun,
                                            score: 5, at: Date().addingTimeInterval(120)))
        #expect(try database.readOrders().first?.id == older.id,
                "the rating's at derived the new order (review, PR #49)")
        #expect(try stamp() == before, "the stamp stayed put: no lastActivityAt bump")
    }

    // MARK: Effective ratings

    @Test("Posting again for the same subject: the later row counts, the earlier is its history")
    func laterRowIsEffective() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let earlier = rating(3, at: 2_000, orderID: order.id)
        let later = rating(5, at: 2_100, orderID: order.id)
        // Posted out of order: selection is by `at`, never arrival.
        try database.postRating(later)
        try database.postRating(earlier)
        let receiver = OrderRating.Subject(kind: OrderRating.Subject.Kind.party, ref: party("_irina").uuidString)
        try database.postRating(rating(4, at: 2_050, orderID: order.id, subject: receiver))
        let effective = try database.effectiveRatings(orderID: order.id, authority: authority)
        #expect(effective.notCounted.isEmpty)
        #expect(effective.counted.map(\.current.value.score) == [4, 5], "one per subject, oldest effective row first")
        let run = try #require(effective.counted.first { $0.current.value.subject == Self.courierRun })
        #expect(run.current.value.id == later.id && run.history.map(\.value.id) == [earlier.id])
        #expect(run.author == me)
    }

    @Test("A member's rating under a trusted key verifies; a reader's reads notEntitled and does not count")
    func memberAndReader() throws {
        let owner = makeDatabase()
        let order = try recordOrder(in: owner)
        let irina = party("_irina"), oleg = party("_oleg")
        let irinaDevice = makeDatabase(keyStore: EphemeralKeyStore())
        let olegDevice = makeDatabase(keyStore: EphemeralKeyStore())
        try irinaDevice.postRating(rating(5, at: 2_000, orderID: order.id, authorRef: irina))
        try olegDevice.postRating(rating(1, at: 2_000, orderID: order.id, authorRef: oleg))
        let authority = TrustRowsTests.FakeAuthority(
            localParty: me, owner: me,
            participants: [Member(ref: irina, canWrite: true, displayName: "Ирина"),
                           Member(ref: oleg, canWrite: false, displayName: "Олег")],
            stamps: [try irinaDevice.signatory().keyID: irina, try olegDevice.signatory().keyID: oleg],
            myKeyID: try owner.signatory().keyID)
        let verdicts = Dictionary(uniqueKeysWithValues: try owner.attestedRatings(orderID: order.id, authority: authority)
            .map { ($0.value.authorRef, $0.verdict) })
        #expect(verdicts[irina] == .verified(
            author: Party(ref: irina, displayName: "Ирина", role: .member(kind: Membership.Role.participant))))
        #expect(verdicts[oleg] == .notEntitled(
            author: Party(ref: oleg, displayName: "Олег", role: .member(kind: Membership.Role.reader))),
            "listed read-only: placed, and entitled to write nothing")
        let effective = try owner.effectiveRatings(orderID: order.id, authority: authority)
        #expect(effective.counted.map(\.author) == [irina])
        #expect(effective.notCounted.map(\.value.authorRef) == [oleg])
    }

    @Test("A score rewritten out of band reads invalid, leaves the effective set and shows as not counted")
    func tamperedScore() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let order = try recordOrder(in: database)
        let earlier = rating(2, at: 2_000, orderID: order.id)
        let later = rating(3, at: 2_100, orderID: order.id)
        try database.postRating(earlier)
        try database.postRating(later)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderRatings" SET "score" = 5 WHERE "id" = ?
                """, arguments: AppDatabase.args([later.id]))
        }
        let attested = try database.attestedRatings(orderID: order.id, authority: authority)
        #expect(attested.map(\.verdict.isVerified) == [true, false])
        #expect(attested[1].verdict == .invalid && attested[1].value.score == 5, "rendered as stored, beside its warning")
        let effective = try database.effectiveRatings(orderID: order.id, authority: authority)
        #expect(effective.counted.map(\.current.value.id) == [earlier.id] && effective.counted[0].history.isEmpty,
                "a forged later row supersedes nothing")
        #expect(effective.notCounted.map(\.value.id) == [later.id])
    }

    // MARK: Summary

    @Test("The summary averages one effective rating per author per order and ignores rows that do not count")
    func summaryAcrossOrders() throws {
        let database = makeDatabase()
        let authority = try privateAuthority(database)
        let provider = OrderRating.Subject(kind: OrderRating.Subject.Kind.provider, ref: "yandex:corp-1")
        let first = try recordOrder(in: database)
        let second = try recordOrder(in: database)
        // First order: 5, then revised to 3 — only the 3 counts.
        try database.postRating(rating(5, at: 2_000, orderID: first.id, subject: provider))
        try database.postRating(rating(3, at: 2_100, orderID: first.id, subject: provider))
        // Second order: a 4, and a later 1 rewritten to 2 out of band — invalid, so the 4 stands.
        try database.postRating(rating(4, at: 3_000, orderID: second.id, subject: provider))
        let tampered = rating(1, at: 3_100, orderID: second.id, subject: provider)
        try database.postRating(tampered)
        try database.queue.write { db in
            try db.execute(sql: """
                UPDATE "orderRatings" SET "score" = 2 WHERE "id" = ?
                """, arguments: AppDatabase.args([tampered.id]))
        }
        // Another subject in the same orders stays out of this summary.
        try database.postRating(rating(1, at: 2_200, orderID: first.id))
        let summary = try database.ratingSummary(
            subjectKind: provider.kind, subjectRef: provider.ref, authority: authority)
        #expect(summary == RatingSummary(count: 2, mean: 3.5))
        #expect(try database.ratingSummary(
            subjectKind: provider.kind, subjectRef: "yandex:corp-2", authority: authority) == nil)
    }
}

import Dependencies
import Foundation
import GRDB
import Testing
import YDeliveryKit
@testable import YDeliveryData

/// Key rows, memberships and the identity authority (the app's Collaboration →
/// "Keys", "Verdicts and entitlement"; Schema → "Stage 1"). CloudKit's own stamps
/// cannot be faked through public API — a locally built `CKRecord` has no creator —
/// so the resolution is a pure function tested here exhaustively, and the authority
/// is exercised with no stamp, which is what a row that has not been to the server
/// looks like. The device pass proves the stamping.
@Suite("Key rows, memberships and the authority")
struct TrustRowsTests {
    private let directory: URL
    private static let container = "iCloud.test"

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustRowsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase(keyStore: any SigningKeyStore = EphemeralKeyStore()) -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: Self.container, keyStore: keyStore)
    }

    private func recordOrder(in database: AppDatabase) throws -> Order {
        let order = Order(
            created: .now, status: .active,
            route: [RoutePoint(latitude: 55, longitude: 37, address: "А")],
            claimID: "claim-\(UUID().uuidString.prefix(8))")
        try database.recordOrder(order)
        return order
    }

    private func party(_ subject: String) -> UUID {
        UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: subject)
    }

    private func member(_ subject: String, canWrite: Bool = true) -> Member {
        Member(ref: party(subject), canWrite: canWrite)
    }

    // MARK: Key rows

    @Test("A key is published once per binding, self-signed over every column; a rewritten key fails")
    func publicationIsIdempotentAndSelfSigned() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let signatory = try database.signatory()
        let me = party("_me")
        for _ in 0..<2 {
            try database.queue.write { db in
                try AppDatabase.publishKeyIfNeeded(orderID: order.id, signatory: signatory, partyRef: me, in: db)
            }
        }
        var keys = try database.participantKeys(orderID: order.id)
        #expect(keys.count == 1, "a retry is a no-op")
        let key = try #require(keys.first)
        #expect(key.id == ParticipantKey.derivedID(
            orderID: order.id, keyID: signatory.keyID, bindingKind: ParticipantKey.BindingKind.cloudkit))
        #expect(key.keyID == signatory.keyID && key.publicKey == signatory.publicKeyBase64)
        #expect(key.partyRef == me && key.bindingKind == ParticipantKey.BindingKind.cloudkit)
        #expect(key.bindingProof == nil && key.boundAt == nil, "the CloudKit binding's proof is the server stamp")
        #expect(key.selfSignatureIsValid)

        var rewritten = key
        rewritten.publicKey = Signatory.ephemeral().publicKeyBase64
        #expect(!rewritten.selfSignatureIsValid, "a rewritten public key no longer matches the key id or the signature")
        var reproved = key
        reproved.bindingProof = "forged"
        #expect(!reproved.selfSignatureIsValid, "the binding columns are signed too")

        try database.queue.write { db in
            try AppDatabase.publishKeyIfNeeded(
                orderID: order.id, signatory: signatory, partyRef: me,
                bindingKind: ParticipantKey.BindingKind.server, in: db)
        }
        keys = try database.participantKeys(orderID: order.id)
        #expect(keys.count == 2, "the same key under a second binding is a second row, not a collision")
    }

    // MARK: Party resolution

    @Test("A creator stamp resolves to a party; the current-user placeholder to the local party; no stamp binds nobody")
    func partyResolution() {
        let me = party("_me"), them = party("_them")
        let kind = CloudKitIdentityAuthority.authorityKind
        #expect(PartyResolution.binding(stampRecordName: "_them", claimedPartyRef: nil, isMine: false, localParty: me)
                == .party(UUID.partyRef(authority: kind, subject: "_them")))
        #expect(PartyResolution.binding(stampRecordName: "_them", claimedPartyRef: them, isMine: false, localParty: me)
                == .party(them), "a claim that agrees with the stamp")
        #expect(PartyResolution.binding(stampRecordName: "_them", claimedPartyRef: me, isMine: false, localParty: me)
                == .conflict, "a claim the stamp contradicts")
        #expect(PartyResolution.binding(stampRecordName: nil, claimedPartyRef: me, isMine: true, localParty: me)
                == .mine, "no stamp yet, but the private key is this device's")
        #expect(PartyResolution.binding(stampRecordName: nil, claimedPartyRef: them, isMine: false, localParty: me)
                == .none, "no stamp yet and not this device's: unverifiable")
        #expect(PartyResolution.binding(stampRecordName: PartyResolution.currentUserDefaultName,
                                        claimedPartyRef: nil, isMine: false, localParty: me)
                == .party(me), "the placeholder is this device's user")
        #expect(PartyResolution.binding(stampRecordName: PartyResolution.currentUserDefaultName,
                                        claimedPartyRef: nil, isMine: true, localParty: nil)
                == .mine, "the placeholder before the device knows its party, on its own key")
        #expect(PartyResolution.binding(stampRecordName: PartyResolution.currentUserDefaultName,
                                        claimedPartyRef: nil, isMine: false, localParty: nil)
                == .none, "the placeholder before the device knows its party, on a foreign key")
    }

    // MARK: Memberships

    @Test("The effective row is the latest; removed dominates an exact tie, then the smallest id; as of a stamp")
    func effectiveRow() {
        let order = UUID(), partyRef = party("_p")
        let t0 = Date(timeIntervalSince1970: 1_000)
        func row(_ role: String, at: TimeInterval, id: String) -> Membership {
            Membership(id: UUID(uuidString: id)!, orderID: order, partyRef: partyRef, role: role,
                       addedAt: t0 + at)
        }
        let a = row(Membership.Role.participant, at: 0, id: "00000000-0000-0000-0000-00000000000a")
        let b = row(Membership.Role.receiver, at: 10, id: "00000000-0000-0000-0000-00000000000b")
        #expect(Membership.effective(among: [a, b])?.role == Membership.Role.receiver, "latest wins")
        let removed = row(Membership.Role.removed, at: 10, id: "00000000-0000-0000-0000-00000000000f")
        #expect(Membership.effective(among: [a, b, removed])?.role == Membership.Role.removed,
                "on an exact tie removed dominates")
        let c = row(Membership.Role.dispatcher, at: 10, id: "00000000-0000-0000-0000-000000000001")
        #expect(Membership.effective(among: [b, c])?.id == c.id, "then the smallest id")
        #expect(Membership.effective(among: [a, b], asOf: t0 + 5)?.role == Membership.Role.participant,
                "as of a stamp before the assignment, the earlier row is in force")
        #expect(Membership.effective(among: [a, b], asOf: t0 - 1) == nil)
        #expect(Membership.effective(among: []) == nil)
    }

    @Test("A mirrored id is one per order, party, writer key and generation")
    func mirroredIDs() {
        let order = UUID(), partyRef = party("_p")
        let one = Membership.mirroredID(orderID: order, partyRef: partyRef, writerKeyID: "p256.v2.aa", generation: 0)
        #expect(one == Membership.mirroredID(orderID: order, partyRef: partyRef, writerKeyID: "p256.v2.aa", generation: 0))
        #expect(one != Membership.mirroredID(orderID: order, partyRef: partyRef, writerKeyID: "p256.v2.bb", generation: 0),
                "two owner devices write two rows")
        #expect(one != Membership.mirroredID(orderID: order, partyRef: partyRef, writerKeyID: "p256.v2.aa", generation: 1),
                "a return after a removal is a new membership")
    }

    @Test("The reconcile mirrors the share, is idempotent, removes what the share dropped, and re-admits")
    func reconcileMirrorsTheShare() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let me = party("_me")
        let members = [Member(ref: me, canWrite: true, isOwner: true), member("_irina"), member("_sergei")]
        let t0 = Date(timeIntervalSince1970: 1_000)

        let first = try database.reconcileMemberships(orderID: order.id, members: members, localParty: me, at: t0)
        #expect(first == MembershipReconciliation(mirrored: 2, removed: 0))
        var rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 2 && rows.allSatisfy { $0.role == Membership.Role.participant && $0.authorRef == me })
        #expect(!rows.contains { $0.partyRef == me }, "the owner is not a participant row")
        let keys = try database.participantKeys(orderID: order.id)
        #expect(keys.count == 1, "the device's key is published in the same transaction")
        for row in rows {
            let payload = CanonicalPayload.payload(
                table: MembershipRow.tableName,
                columns: CanonicalPayload.signedColumns[MembershipRow.tableName] ?? [],
                values: CanonicalPayload.databaseValues(row.signedBindings))
            #expect(row.signingKeyID == keys[0].keyID)
            #expect(Signatory.verify(payload: payload, signatureBase64: row.signature ?? "",
                                     publicKeyBase64: keys[0].publicKey), "signed under the published key")
        }

        let again = try database.reconcileMemberships(orderID: order.id, members: members, localParty: me, at: t0 + 1)
        #expect(again == MembershipReconciliation(mirrored: 0, removed: 0), "a second pass writes nothing")

        let withoutSergei = try database.reconcileMemberships(
            orderID: order.id, members: [members[0], members[1]], localParty: me, at: t0 + 10)
        #expect(withoutSergei == MembershipReconciliation(mirrored: 0, removed: 1))
        rows = try database.memberships(orderID: order.id)
        let sergei = rows.filter { $0.partyRef == party("_sergei") }
        #expect(sergei.count == 2 && Membership.effective(among: sergei)?.role == Membership.Role.removed)
        #expect(Membership.effective(among: sergei, asOf: t0 + 5)?.role == Membership.Role.participant,
                "what Sergei wrote while a member stays entitled as of its stamp")

        let readmitted = try database.reconcileMemberships(orderID: order.id, members: members, localParty: me, at: t0 + 20)
        #expect(readmitted == MembershipReconciliation(mirrored: 1, removed: 0), "a return after a removal is a new row")
        let sergeiAgain = try database.memberships(orderID: order.id).filter { $0.partyRef == party("_sergei") }
        #expect(sergeiAgain.count == 3 && Membership.effective(among: sergeiAgain)?.role == Membership.Role.participant)
    }

    @Test("A role assignment is a caller-held row that the next reconcile leaves alone")
    func roleAssignment() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let me = party("_me")
        let members = [Member(ref: me, canWrite: true, isOwner: true), member("_irina")]
        let t0 = Date(timeIntervalSince1970: 1_000)
        try database.reconcileMemberships(orderID: order.id, members: members, localParty: me, at: t0)
        let assigned = try database.setMembershipRole(
            orderID: order.id, partyRef: party("_irina"), role: Membership.Role.receiver, localParty: me, at: t0 + 10)
        let rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 2 && rows.contains { $0.id == assigned.id })
        #expect(Membership.effective(among: rows)?.role == Membership.Role.receiver)
        try database.reconcileMemberships(orderID: order.id, members: members, localParty: me, at: t0 + 20)
        #expect(try database.memberships(orderID: order.id).count == 2, "a live row needs no mirror")
        let back = try database.setMembershipRole(
            orderID: order.id, partyRef: party("_irina"), role: Membership.Role.participant, localParty: me, at: t0 + 30)
        #expect(back.id != assigned.id, "every assignment is its own row")
        #expect(Membership.effective(among: try database.memberships(orderID: order.id))?.role == Membership.Role.participant)
    }

    /// Two of the owner's devices reconcile one share while apart — each in its own
    /// store, as offline devices are — and sync later: both rows exist, both are valid
    /// under their own key, and the selection yields one role. A device that already
    /// sees a live row writes none, which is the idempotence the first test pins.
    @Test("Two owner devices mirror one share as two valid rows with one effective role")
    func twoDevicesMirrorOneShare() throws {
        let phone = makeDatabase(keyStore: EphemeralKeyStore())
        let tabletDirectory = directory.appendingPathComponent("tablet", isDirectory: true)
        let tablet = AppDatabase(
            directory: tabletDirectory, providerAccountRef: "test:unattributed",
            containerIdentifier: Self.container, keyStore: EphemeralKeyStore())
        let order = try recordOrder(in: phone)
        try tablet.recordOrder(order)
        let me = party("_me")
        let members = [Member(ref: me, canWrite: true, isOwner: true), member("_irina")]
        try phone.reconcileMemberships(orderID: order.id, members: members, localParty: me)
        try tablet.reconcileMemberships(orderID: order.id, members: members, localParty: me)
        let synced = try phone.memberships(orderID: order.id) + tablet.memberships(orderID: order.id)
        #expect(synced.count == 2, "each device writes its own row under its own key")
        #expect(Set(synced.map(\.id)).count == 2 && Set(synced.map(\.signingKeyID)).count == 2,
                "the mirrored id carries the writer's key, so the rows never merge into one record")
        #expect(Set(synced.map(\.role)) == [Membership.Role.participant], "same role, one effective answer")
        #expect(Membership.effective(among: synced) != nil)
        let keys = try phone.participantKeys(orderID: order.id) + tablet.participantKeys(orderID: order.id)
        #expect(Set(keys.map(\.keyID)).count == 2, "each device published its own key")
    }

    // MARK: Entitlement and members

    @Test("The entitlement matrix")
    func entitlementMatrix() {
        let leg = UUID()
        let events = OrderEventRow.tableName, messages = OrderMessageRow.tableName
        let memberships = MembershipRow.tableName, keys = ParticipantKeyRow.tableName
        #expect(Entitlement.mayWrite(.owner, table: events, legRef: nil))
        #expect(Entitlement.mayWrite(.owner, table: memberships, legRef: nil))
        #expect(!Entitlement.mayWrite(.owner, table: keys, legRef: nil), "a key row is entitled only to its binding's party")
        #expect(Entitlement.mayWrite(.member(kind: Membership.Role.receiver), table: messages, legRef: nil))
        #expect(!Entitlement.mayWrite(.member(kind: Membership.Role.receiver), table: events, legRef: nil))
        #expect(!Entitlement.mayWrite(.member(kind: Membership.Role.receiver), table: memberships, legRef: nil))
        #expect(Entitlement.mayWrite(.courier(legRef: leg), table: events, legRef: leg))
        #expect(!Entitlement.mayWrite(.courier(legRef: leg), table: events, legRef: nil), "not the order's platform leg")
        #expect(!Entitlement.mayWrite(.courier(legRef: leg), table: events, legRef: UUID()), "not another leg")
        #expect(Entitlement.mayWrite(.courier(legRef: leg), table: messages, legRef: nil))
        #expect(!Entitlement.mayWrite(.unknown, table: messages, legRef: nil))
    }

    @Test("Members merge the share with the rows: the share grants, a row's role wins, a pending invitee is not in")
    func memberMerge() {
        let order = UUID()
        let summary = ShareSummary(
            ownerRecordName: "_owner", ownerName: "Пётр",
            participants: [
                .init(recordName: "_irina", displayName: "Ирина", accepted: true, canWrite: true),
                .init(recordName: "_pending", displayName: nil, accepted: false, canWrite: true),
                .init(recordName: "_reader", displayName: nil, accepted: true, canWrite: false),
            ])
        let rows = [
            Membership(orderID: order, partyRef: party("_irina"), role: Membership.Role.receiver, addedAt: .now),
            Membership(orderID: order, partyRef: party("_reader"), role: Membership.Role.removed, addedAt: .now),
        ]
        let members = MemberList.merge(summary: summary, memberships: rows)
        #expect(members.count == 3)
        let owner = try? #require(members.first { $0.isOwner })
        #expect(owner?.ref == party("_owner") && owner?.displayName == "Пётр" && owner?.canWrite == true)
        #expect(members.first { $0.ref == party("_irina") }?.role == Membership.Role.receiver, "a row's role wins")
        #expect(!members.contains { $0.ref == party("_pending") }, "not accepted: not a member")
        let reader = members.first { $0.ref == party("_reader") }
        #expect(reader?.canWrite == false && reader?.role == nil, "the share lists them again: a removed row is not a role")
        #expect(MemberList.merge(summary: nil, memberships: rows).isEmpty, "a private order has no members")
    }

    @Test("The authority knows the local party, its own key before any stamp, and no one else's")
    func authorityBasics() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let authority = CloudKitIdentityAuthority(database: database, containerIdentifier: Self.container)
        #expect(authority.localParty == nil)
        let me = party("_me")
        try database.noteLocalIdentity(
            authority: CloudKitIdentityAuthority.authorityKey(containerIdentifier: Self.container),
            subject: "_me", partyRef: me)
        #expect(authority.localParty == me)
        let mine = try database.signatory()
        let foreign = Signatory.ephemeral()
        try database.queue.write { db in
            try AppDatabase.publishKeyIfNeeded(orderID: order.id, signatory: mine, partyRef: me, in: db)
            try AppDatabase.publishKeyIfNeeded(orderID: order.id, signatory: foreign, partyRef: party("_them"), in: db)
        }
        try withDependencies {
            $0.context = .test
        } operation: {
            let keys = try database.participantKeys(orderID: order.id)
            let myRow = try #require(keys.first { $0.keyID == mine.keyID })
            let theirRow = try #require(keys.first { $0.keyID == foreign.keyID })
            #expect(authority.binding(of: myRow) == .mine, "no stamp yet, but the private key is this device's")
            #expect(authority.binding(of: theirRow) == .none, "no stamp yet and not ours: unverifiable")
            #expect(authority.members(of: order.id).isEmpty, "a private order lists no members")
        }
    }
}

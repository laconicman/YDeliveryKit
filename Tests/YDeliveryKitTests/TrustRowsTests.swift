import Dependencies
import Foundation
import GRDB
import Testing
import YDeliveryKit
@testable import YDeliveryData

/// Key rows, memberships and the identity authority (the app's Collaboration →
/// "Keys", "Verdicts and entitlement"; Schema → "Stage 1"). CloudKit's own stamps
/// cannot be faked through public API — a locally built `CKRecord` has no creator —
/// so the resolution is a pure function tested here exhaustively, the reconcile and
/// the trust filter run against a fake authority that plays the stamps, and the
/// CloudKit authority is exercised with no stamp, which is what a row that has not
/// been to the server looks like. The device pass proves the stamping.
@Suite("Key rows, memberships and the authority")
struct TrustRowsTests {
    private let directory: URL
    private static let container = "iCloud.test"

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TrustRowsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase(
        in directory: URL? = nil, keyStore: any SigningKeyStore = EphemeralKeyStore()
    ) -> AppDatabase {
        AppDatabase(
            directory: directory ?? self.directory, providerAccountRef: "test:unattributed",
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

    /// An authority that plays CloudKit's part: the share's owner and participants,
    /// and a stamp per key id as the server would have put it. A key with no stamp is
    /// `.mine` when its id is this device's, else unbound — the pre-sync state.
    struct FakeAuthority: IdentityAuthority {
        var localParty: UUID?
        var owner: UUID?
        var participants: [Member] = []
        var stamps: [String: UUID] = [:]
        var myKeyID: String?
        /// A shared order whose owner this device cannot resolve yet.
        var ownerUnresolved = false
        /// A shared order whose share is not cached here: no roster at all.
        var rosterUnavailable = false

        func binding(of key: ParticipantKey) -> KeyBinding {
            if let stamped = stamps[key.keyID] {
                return key.partyRef == nil || key.partyRef == stamped ? .party(stamped) : .conflict
            }
            return key.keyID == myKeyID ? .mine : .none
        }

        func owner(of orderID: Order.ID) -> Ownership {
            if ownerUnresolved { return .unresolved }
            return owner.map(Ownership.party) ?? .local
        }

        func members(of orderID: Order.ID) -> [Member] {
            if rosterUnavailable { return [] }
            return (owner.map { [Member(ref: $0, canWrite: true, isOwner: true)] } ?? []) + participants
        }
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
        let placeholder = PartyResolution.currentUserDefaultName
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
        #expect(PartyResolution.binding(stampRecordName: placeholder, claimedPartyRef: nil, isMine: false, localParty: me)
                == .party(me), "the placeholder is this device's user")
        #expect(PartyResolution.binding(stampRecordName: placeholder, claimedPartyRef: nil, isMine: true, localParty: nil)
                == .mine, "the placeholder before the device knows its party, on its own key")
        #expect(PartyResolution.binding(stampRecordName: placeholder, claimedPartyRef: nil, isMine: false, localParty: nil)
                == .none, "the placeholder before the device knows its party, on a foreign key")
        #expect(PartyResolution.party(forRecordName: placeholder, localParty: me) == me)
        #expect(PartyResolution.party(forRecordName: placeholder, localParty: nil) == nil,
                "no fabricated party for a device that does not know itself")
        #expect(PartyResolution.party(forRecordName: "_them", localParty: nil) == them)
    }

    @Test("Ownership comes from the zone first and the share second")
    func ownershipResolution() {
        let me = party("_me")
        let placeholder = PartyResolution.currentUserDefaultName
        let shared = ShareSummary(ownerRecordName: placeholder, ownerName: nil, participants: [])
        #expect(PartyResolution.ownership(zoneOwnerName: nil, share: nil, localParty: me) == .local,
                "a root that never synced is this device's")
        #expect(PartyResolution.ownership(zoneOwnerName: "_them", share: nil, localParty: me) == .party(party("_them")),
                "another record name's zone is theirs, share cached or not")
        #expect(PartyResolution.ownership(zoneOwnerName: "_them", share: shared, localParty: me) == .party(party("_them")))
        #expect(PartyResolution.ownership(zoneOwnerName: placeholder, share: nil, localParty: me) == .local,
                "our zone without a share: a private order")
        #expect(PartyResolution.ownership(zoneOwnerName: placeholder, share: shared, localParty: me) == .party(me),
                "our zone with a share: we are its owner")
        #expect(PartyResolution.ownership(zoneOwnerName: placeholder, share: shared, localParty: nil) == .unresolved,
                "until the device knows itself, nobody is")
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
        var authority = FakeAuthority(
            localParty: me, owner: me, participants: [member("_irina"), member("_sergei")],
            myKeyID: try database.signatory().keyID)
        let t0 = Date(timeIntervalSince1970: 1_000)

        let first = try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0)
        #expect(first == MembershipReconciliation(mirrored: 2, removed: 0))
        var rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 2 && rows.allSatisfy { $0.role == Membership.Role.participant && $0.authorRef == me })
        #expect(!rows.contains { $0.partyRef == me }, "the owner is not a participant row")
        let keys = try database.participantKeys(orderID: order.id)
        #expect(keys.count == 1, "the device's key is published in the same transaction")
        #expect(rows.allSatisfy { $0.signingKeyID == keys[0].keyID && $0.signatureIsValid(under: keys[0]) },
                "signed under the published key")
        #expect(try database.ownerMemberships(orderID: order.id, authority: authority).count == 2,
                "this device's own key counts before any stamp: it is the owner's")

        let again = try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 1)
        #expect(again == MembershipReconciliation(mirrored: 0, removed: 0), "a second pass writes nothing")

        authority.participants = [member("_irina")]
        let withoutSergei = try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 10)
        #expect(withoutSergei == MembershipReconciliation(mirrored: 0, removed: 1))
        rows = try database.memberships(orderID: order.id)
        let sergei = rows.filter { $0.partyRef == party("_sergei") }
        #expect(sergei.count == 2 && Membership.effective(among: sergei)?.role == Membership.Role.removed)
        #expect(Membership.effective(among: sergei, asOf: t0 + 5)?.role == Membership.Role.participant,
                "what Sergei wrote while a member stays entitled as of its stamp")

        authority.participants = [member("_irina"), member("_sergei")]
        let readmitted = try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 20)
        #expect(readmitted == MembershipReconciliation(mirrored: 1, removed: 0), "a return after a removal is a new row")
        let sergeiAgain = try database.memberships(orderID: order.id).filter { $0.partyRef == party("_sergei") }
        #expect(sergeiAgain.count == 3 && Membership.effective(among: sergeiAgain)?.role == Membership.Role.participant)
    }

    @Test("The reconcile mirrors the share's permission: a reader row, a new row per change, idempotent, the admission id unchanged")
    func reconcileMirrorsPermission() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let me = party("_me"), irina = party("_irina")
        var authority = FakeAuthority(
            localParty: me, owner: me, participants: [member("_irina", canWrite: false)],
            myKeyID: try database.signatory().keyID)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let keyID = try database.signatory().keyID

        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0)
                == MembershipReconciliation(mirrored: 1, removed: 0))
        var rows = try database.memberships(orderID: order.id)
        #expect(rows.map(\.role) == [Membership.Role.reader], "listed read-only: admitted as a reader")
        #expect(rows[0].id == Membership.mirroredID(orderID: order.id, partyRef: irina, writerKeyID: keyID, generation: 0),
                "the admission row's id is what 0.5.2 derived")
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 1)
                == MembershipReconciliation(mirrored: 0, removed: 0), "a second pass writes nothing")

        authority.participants = [member("_irina", canWrite: true)]
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 10)
                == MembershipReconciliation(mirrored: 1, removed: 0), "a restored permission is a new row")
        rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 2 && Membership.effective(among: rows)?.role == Membership.Role.participant)
        #expect(Membership.effective(among: rows, asOf: t0 + 5)?.role == Membership.Role.reader,
                "the change is dated: as of before it she was a reader")

        authority.participants = [member("_irina", canWrite: false)]
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 20)
                == MembershipReconciliation(mirrored: 1, removed: 0), "a downgrade is a new row")
        rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 3 && Membership.effective(among: rows)?.role == Membership.Role.reader)
        #expect(Set(rows.map(\.id)).count == 3, "three rows, three ids")
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 21)
                == MembershipReconciliation(mirrored: 0, removed: 0))
    }

    @Test("A role assignment is a caller-held row; a retry under the same id is one row; the next reconcile leaves it alone")
    func roleAssignment() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let me = party("_me")
        let authority = FakeAuthority(
            localParty: me, owner: me, participants: [member("_irina")], myKeyID: try database.signatory().keyID)
        let t0 = Date(timeIntervalSince1970: 1_000)
        try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0)
        let assignment = UUID()
        let assigned = try database.setMembershipRole(
            orderID: order.id, partyRef: party("_irina"), role: Membership.Role.receiver, id: assignment,
            localParty: me, at: t0 + 10)
        let retried = try database.setMembershipRole(
            orderID: order.id, partyRef: party("_irina"), role: Membership.Role.receiver, id: assignment,
            localParty: me, at: t0 + 11)
        let rows = try database.memberships(orderID: order.id)
        #expect(rows.count == 2 && rows.contains { $0.id == assigned.id }, "a retry of one assignment is one row")
        #expect(assigned.signature != nil && assigned.signingKeyID != nil, "the returned row is the stored, signed one")
        #expect(retried == assigned && retried.addedAt == t0 + 10,
                "a retry returns the row that exists, with its own stamp, not this call's copy")
        #expect(Membership.effective(among: rows)?.role == Membership.Role.receiver)
        try database.reconcileMemberships(orderID: order.id, authority: authority, at: t0 + 20)
        #expect(try database.memberships(orderID: order.id).count == 2, "a live row needs no mirror")
        let back = try database.setMembershipRole(
            orderID: order.id, partyRef: party("_irina"), role: Membership.Role.participant, localParty: me, at: t0 + 30)
        #expect(back.id != assigned.id, "a later assignment is its own row")
        #expect(Membership.effective(among: try database.memberships(orderID: order.id))?.role == Membership.Role.participant)
    }

    /// A store that fails before yielding a key — the custody failure that must write
    /// no membership fact: an unsigned row would count for nothing and block the
    /// signed one a later pass could write.
    struct RefusingKeyStore: SigningKeyStore {
        func signatory() throws -> Signatory {
            throw KeyCustodyError(operation: .read, status: errSecInteractionNotAllowed)
        }
    }

    @Test("A custody failure writes no membership fact; the next pass with a key writes signed rows")
    func custodyFailureWritesNothing() throws {
        let refusing = makeDatabase(keyStore: RefusingKeyStore())
        let order = try recordOrder(in: refusing)
        let me = party("_me")
        let authority = FakeAuthority(localParty: me, owner: me, participants: [member("_irina")])
        #expect(throws: KeyCustodyError.self) {
            try refusing.reconcileMemberships(orderID: order.id, authority: authority)
        }
        #expect(throws: KeyCustodyError.self) {
            try refusing.setMembershipRole(
                orderID: order.id, partyRef: party("_irina"), role: Membership.Role.receiver, localParty: me)
        }
        #expect(try refusing.memberships(orderID: order.id).isEmpty, "nothing unsigned was written")
        let recovered = makeDatabase()
        var withKey = authority
        withKey.myKeyID = try recovered.signatory().keyID
        #expect(try recovered.reconcileMemberships(orderID: order.id, authority: withKey).mirrored == 1)
        #expect(try recovered.memberships(orderID: order.id).allSatisfy { $0.signature != nil })
    }

    @Test("A role a participant appended counts for nothing: not in the members, not live for the reconcile")
    func forgedRoleIsNotReported() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let me = party("_me"), irina = party("_irina")
        let ownerKey = try database.signatory()
        var authority = FakeAuthority(localParty: me, owner: me, participants: [member("_irina")], myKeyID: ownerKey.keyID)
        try database.reconcileMemberships(orderID: order.id, authority: authority)

        // Irina's device: her own key, published, stamped by the server as hers, and a
        // row that names her dispatcher, signed correctly under it.
        let irinaKey = Signatory.ephemeral()
        let forged = Membership(orderID: order.id, partyRef: irina, role: Membership.Role.dispatcher, authorRef: irina)
        try database.queue.write { db in
            try AppDatabase.publishKeyIfNeeded(orderID: order.id, signatory: irinaKey, partyRef: irina, in: db)
            try AppDatabase.insertSigned(table: MembershipRow.tableName, bindings: forged.signedBindings,
                                         signatory: irinaKey, into: db)
        }
        authority.stamps[irinaKey.keyID] = irina
        let counting = try database.ownerMemberships(orderID: order.id, authority: authority)
        #expect(counting.count == 1 && counting.first?.role == Membership.Role.participant,
                "a correctly signed row under a key that is not the owner's does not count")
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority)
                == MembershipReconciliation(mirrored: 0, removed: 0))
        // And a row under the owner's own key id with a bad signature — a rewrite.
        var tampered = try database.memberships(orderID: order.id).first { $0.signingKeyID == ownerKey.keyID }!
        tampered.role = Membership.Role.courier
        let keys = try database.participantKeys(orderID: order.id)
        #expect(!tampered.signatureIsValid(under: keys.first { $0.keyID == ownerKey.keyID }!))
    }

    /// Two of the owner's devices reconcile one share while apart — each in its own
    /// store, as offline devices are — and sync later: both rows exist, both are valid
    /// under their own key, and the selection yields one role. A device that already
    /// sees a live row writes none, which the idempotence test pins.
    @Test("Two owner devices mirror one share as two valid rows with one effective role")
    func twoDevicesMirrorOneShare() throws {
        let phone = makeDatabase()
        let tablet = makeDatabase(in: directory.appendingPathComponent("tablet", isDirectory: true))
        let order = try recordOrder(in: phone)
        try tablet.recordOrder(order)
        let me = party("_me")
        let phoneAuthority = FakeAuthority(
            localParty: me, owner: me, participants: [member("_irina")], myKeyID: try phone.signatory().keyID)
        let tabletAuthority = FakeAuthority(
            localParty: me, owner: me, participants: [member("_irina")], myKeyID: try tablet.signatory().keyID)
        try phone.reconcileMemberships(orderID: order.id, authority: phoneAuthority)
        try tablet.reconcileMemberships(orderID: order.id, authority: tabletAuthority)
        let synced = try phone.memberships(orderID: order.id) + tablet.memberships(orderID: order.id)
        #expect(synced.count == 2, "each device writes its own row under its own key")
        #expect(Set(synced.map(\.id)).count == 2 && Set(synced.map(\.signingKeyID)).count == 2,
                "the mirrored id carries the writer's key, so the rows never merge into one record")
        #expect(Set(synced.map(\.role)) == [Membership.Role.participant], "same role, one effective answer")
        #expect(Membership.effective(among: synced) != nil)
        let keys = try phone.participantKeys(orderID: order.id) + tablet.participantKeys(orderID: order.id)
        #expect(Set(keys.map(\.keyID)).count == 2, "each device published its own key")
    }

    @Test("A device that is not the owner's writes nothing, and an unresolved owner lets nobody's rows count")
    func participantDeviceWritesNothing() throws {
        let database = makeDatabase()
        let order = try recordOrder(in: database)
        let irina = party("_irina")
        var authority = FakeAuthority(
            localParty: irina, owner: party("_me"), participants: [member("_irina")],
            myKeyID: try database.signatory().keyID)
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority)
                == MembershipReconciliation(mirrored: 0, removed: 0))
        #expect(try database.memberships(orderID: order.id).isEmpty)

        // Irina signs herself a role on an order whose owner this device cannot resolve:
        // the fallback that once made the local party the owner is gone (review, PR #47).
        let forged = Membership(orderID: order.id, partyRef: irina, role: Membership.Role.dispatcher, authorRef: irina)
        let key = try database.signatory()
        try database.queue.write { db in
            try AppDatabase.publishKeyIfNeeded(orderID: order.id, signatory: key, partyRef: irina, in: db)
            try AppDatabase.insertSigned(table: MembershipRow.tableName, bindings: forged.signedBindings,
                                         signatory: key, into: db)
        }
        authority.owner = nil
        authority.ownerUnresolved = true
        #expect(try database.ownerMemberships(orderID: order.id, authority: authority).isEmpty,
                "nobody is the owner until the device knows who is")
        #expect(try database.reconcileMemberships(orderID: order.id, authority: authority)
                == MembershipReconciliation(mirrored: 0, removed: 0))
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

    @Test("Members merge the share with the rows: the share grants, a row's role wins, the placeholder is this device")
    func memberMerge() {
        let order = UUID()
        let me = party("_me")
        let summary = ShareSummary(
            ownerRecordName: PartyResolution.currentUserDefaultName, ownerName: "Пётр",
            participants: [
                .init(recordName: "_irina", displayName: "Ирина", accepted: true, canWrite: true),
                .init(recordName: "_pending", displayName: nil, accepted: false, canWrite: true),
                .init(recordName: "_reader", displayName: nil, accepted: true, canWrite: false),
            ])
        let rows = [
            Membership(orderID: order, partyRef: party("_irina"), role: Membership.Role.receiver, addedAt: .now),
            Membership(orderID: order, partyRef: party("_reader"), role: Membership.Role.removed, addedAt: .now),
        ]
        let members = MemberList.merge(summary: summary, memberships: rows, localParty: me)
        #expect(members.count == 3)
        let owner = members.first { $0.isOwner }
        #expect(owner?.ref == me, "the share names its owner by the placeholder on the owner's device: that is us")
        #expect(owner?.displayName == "Пётр" && owner?.canWrite == true)
        #expect(members.first { $0.ref == party("_irina") }?.role == Membership.Role.receiver, "a row's role wins")
        #expect(!members.contains { $0.ref == party("_pending") }, "not accepted: not a member")
        let reader = members.first { $0.ref == party("_reader") }
        #expect(reader?.canWrite == false && reader?.role == nil, "the share lists them again: a removed row is not a role")
        #expect(summary.ownerRef(localParty: nil) == nil, "a device that does not know itself fabricates no owner")
        #expect(MemberList.merge(summary: summary, memberships: rows, localParty: nil).first { $0.isOwner } == nil)
        #expect(MemberList.merge(summary: nil, memberships: rows, localParty: me).isEmpty, "a private order has no members")
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
            #expect(try database.reconcileMemberships(orderID: order.id, authority: authority)
                    == MembershipReconciliation(mirrored: 0, removed: 0), "a private order has nobody to mirror")
        }
    }
}

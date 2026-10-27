import Foundation
import GRDB

// The share's mirror (the app's Schema → "Stage 1" → `memberships`): the owner's
// device writes a signed `participant` row for every accepted share participant
// without a live one, after each sync pass, and a `removed` row for every party
// the share no longer lists; a role assignment is a new row under a caller-held
// id. Roles live here and in `legs`, never on `participantKeys`, never in a
// writer's claim. YD-45's Kit half.

extension Membership {
    /// The frozen v2 list's values, as the row binds and stores them.
    var signedBindings: [(any DatabaseValueConvertible)?] {
        [id, orderID, partyRef, role, addedAt.timeIntervalSince1970, authorRef]
    }

    /// Whether the row's signature verifies under `key` — the key row its
    /// `signingKeyID` names, already known to be the owner's.
    func signatureIsValid(under key: ParticipantKey) -> Bool {
        guard let signature, signingKeyID == key.keyID else { return false }
        let payload = CanonicalPayload.payload(
            table: MembershipRow.tableName,
            columns: CanonicalPayload.signedColumns[MembershipRow.tableName] ?? [],
            values: CanonicalPayload.databaseValues(signedBindings))
        return Signatory.verify(payload: payload, signatureBase64: signature, publicKeyBase64: key.publicKey)
    }
}

/// What one reconcile pass wrote.
public struct MembershipReconciliation: Hashable, Sendable {
    /// Share participants that gained a mirrored row: an admission as `participant`
    /// or `reader`, or a permission change within one.
    public var mirrored: Int
    /// Parties with a live row the share no longer lists, now `removed`.
    public var removed: Int

    public init(mirrored: Int, removed: Int) {
        self.mirrored = mirrored
        self.removed = removed
    }
}

extension AppDatabase {
    /// The order's membership rows, oldest first — every row, as the role's history;
    /// ``Membership/effective(among:)`` selects the one in force among the rows that
    /// count, which ``ownerMemberships(orderID:authority:)`` yields.
    public func memberships(orderID: Order.ID) throws -> [Membership] {
        try queue.read { db in try Self.memberships(orderID: orderID, in: db) }
    }

    static func memberships(orderID: Order.ID, in db: Database) throws -> [Membership] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM "memberships" WHERE "orderID" = ?
            ORDER BY "addedAt", "id"
            """, arguments: args([orderID])).map(membership)
    }

    private static func membership(_ row: Row) -> Membership {
        Membership(
            id: row["id"], orderID: row["orderID"], partyRef: row["partyRef"], role: row["role"],
            addedAt: Date(timeIntervalSince1970: row["addedAt"]),
            authorRef: row["authorRef"], signingKeyID: row["signingKeyID"], signature: row["signature"])
    }

    /// The membership rows that count for roles: only rows that read *verified* as the
    /// owner's — signed under a key row of this order whose self-signature holds and
    /// whose binding the authority resolves to the order's owner (or this device's own
    /// key, before any stamp, when this device is the owner). A row anyone else
    /// appends, a `removed` for the owner included, counts for nothing here and
    /// changes nobody's role; the verdicts render it as *notEntitled* beside the rows
    /// that count.
    public func ownerMemberships(orderID: Order.ID, authority: any IdentityAuthority) throws -> [Membership] {
        switch authority.owner(of: orderID) {
        case .local:
            try ownerMemberships(orderID: orderID, keysTrustedBy: authority,
                                 ownerRef: authority.localParty, isLocalOwner: true)
        case .party(let owner):
            try ownerMemberships(orderID: orderID, keysTrustedBy: authority,
                                 ownerRef: owner, isLocalOwner: owner == authority.localParty)
        case .unresolved:
            []
        }
    }

    func ownerMemberships(
        orderID: Order.ID, keysTrustedBy authority: any IdentityAuthority,
        ownerRef: UUID?, isLocalOwner: Bool
    ) throws -> [Membership] {
        let ownerKeys = try participantKeys(orderID: orderID)
            .filter(\.selfSignatureIsValid)
            .filter { key in
                switch authority.binding(of: key) {
                case .party(let party): party == ownerRef
                case .mine: isLocalOwner
                case .none, .conflict: false
                }
            }
            .reduce(into: [String: ParticipantKey]()) { $0[$1.keyID] = $1 }
        return try memberships(orderID: orderID).filter { row in
            guard let keyID = row.signingKeyID, let key = ownerKeys[keyID] else { return false }
            return row.signatureIsValid(under: key)
        }
    }

    /// Mirrors the share into rows, owner-side: every party the authority lists without
    /// a live row that counts gains a signed `participant` row under the derived id —
    /// `reader` when the share lists the party read-only — and a party whose live row's
    /// standing differs from the share's permission gains a new row saying so, under the
    /// next `revision` of the same admission, so a downgrade or a restored permission is
    /// dated like a removal (review, PR #48); every
    /// party with a live row the share no longer lists gains a signed `removed` row. The
    /// device's key is published into the order in the same transaction, so the rows'
    /// signatures have a key row to verify under; a second pass over the same share
    /// writes nothing. On a device that is not the owner's the pass writes nothing and
    /// says so in the outcome — the rows it would write would count for nothing. A key
    /// that cannot be reached throws before any row is written: a membership fact that
    /// cannot be signed counts for nothing, and a later pass with a key would see it
    /// as live and never replace it (review, PR #47).
    @discardableResult
    public func reconcileMemberships(
        orderID: Order.ID, authority: any IdentityAuthority, at now: Date = Date()
    ) throws -> MembershipReconciliation {
        // Only the share's owner mirrors it, and only once this device knows it is the
        // owner: a private order has nobody to mirror, an unresolved owner nobody who may.
        guard case .party(let owner) = authority.owner(of: orderID),
              let localParty = authority.localParty, owner == localParty
        else { return MembershipReconciliation(mirrored: 0, removed: 0) }
        let members = authority.members(of: orderID)
        let signatory = try signatory()
        let listed = Set(members.filter { !$0.isOwner }.map(\.ref))
        let counting = try ownerMemberships(
            orderID: orderID, keysTrustedBy: authority, ownerRef: owner, isLocalOwner: true)
        return try queue.write { db in
            try Self.publishKeyIfNeeded(orderID: orderID, signatory: signatory, partyRef: localParty, in: db)
            var outcome = MembershipReconciliation(mirrored: 0, removed: 0)
            for member in members.filter({ !$0.isOwner }).sorted(by: { $0.ref.uuidString < $1.ref.uuidString }) {
                let party = member.ref
                let own = counting.filter { $0.partyRef == party }
                let effective = Membership.effective(among: own)
                let wanted = member.canWrite ? Membership.Role.participant : Membership.Role.reader
                let removals = own.filter { $0.role == Membership.Role.removed }
                var revision = 0
                if let effective, effective.role != Membership.Role.removed {
                    // Admitted already: a row is due only when the share's permission and
                    // the row's standing differ; the revision counts this admission's rows.
                    guard Membership.standing(of: effective.role) != wanted else { continue }
                    let since = removals.map(\.addedAt).max()
                    revision = own.filter { row in since.map { row.addedAt > $0 } ?? true }.count
                }
                let row = Membership(
                    id: Membership.mirroredID(
                        orderID: orderID, partyRef: party, writerKeyID: signatory.keyID,
                        generation: removals.count, revision: revision),
                    orderID: orderID, partyRef: party, role: wanted,
                    addedAt: now, authorRef: localParty)
                if try Self.insertSigned(table: MembershipRow.tableName, bindings: row.signedBindings,
                                         signatory: signatory, into: db) {
                    outcome.mirrored += 1
                }
            }
            for party in Set(counting.map(\.partyRef)).subtracting(listed).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let effective = Membership.effective(among: counting.filter { $0.partyRef == party }),
                      effective.role != Membership.Role.removed
                else { continue }
                let row = Membership(
                    orderID: orderID, partyRef: party, role: Membership.Role.removed,
                    addedAt: now, authorRef: localParty)
                if try Self.insertSigned(table: MembershipRow.tableName, bindings: row.signedBindings,
                                         signatory: signatory, into: db) {
                    outcome.removed += 1
                }
            }
            return outcome
        }
    }

    /// A role assignment by the owner — receiver, dispatcher, courier, or back to
    /// participant — as a new row under a caller-held `id`: a derived id would make
    /// every later assignment collide with the first and vanish, and a retry of one
    /// assignment passes the same id so `INSERT OR IGNORE` recognises it. The effective
    /// role is the latest row; earlier rows stay as the role's history. Throws when the
    /// key cannot be reached: an unsigned assignment would count for nothing. Returns
    /// the row as stored — on a retry, the original with its own stamp and signature,
    /// not this call's copy (review, PR #47).
    @discardableResult
    public func setMembershipRole(
        orderID: Order.ID, partyRef: UUID, role: String, id: UUID = UUID(),
        localParty: UUID?, at now: Date = Date()
    ) throws -> Membership {
        let signatory = try signatory()
        let row = Membership(id: id, orderID: orderID, partyRef: partyRef, role: role, addedAt: now, authorRef: localParty)
        return try queue.write { db in
            try Self.publishKeyIfNeeded(orderID: orderID, signatory: signatory, partyRef: localParty, in: db)
            try Self.insertSigned(table: MembershipRow.tableName, bindings: row.signedBindings,
                                  signatory: signatory, into: db)
            guard let stored = try Self.membership(id: id, in: db) else {
                preconditionFailure("the assignment row exists after INSERT OR IGNORE")
            }
            return stored
        }
    }

    private static func membership(id: UUID, in db: Database) throws -> Membership? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM "memberships" WHERE "id" = ?
            """, arguments: args([id])).map(membership)
    }
}

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
}

/// What one reconcile pass wrote.
public struct MembershipReconciliation: Hashable, Sendable {
    /// Share participants that gained a mirrored `participant` row.
    public var mirrored: Int
    /// Parties with a live row the share no longer lists, now `removed`.
    public var removed: Int
}

extension AppDatabase {
    /// The order's membership rows, oldest first — every row, as the role's history;
    /// ``Membership/effective(among:)`` selects the one in force.
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

    /// Mirrors the share into rows, owner-side: `members` is the authority's list for
    /// the order (the share's owner and accepted participants), `localParty` the
    /// writer's party. Every listed party without a live row gains a mirrored
    /// `participant` row under the derived id; every party with a live row the share
    /// no longer lists gains a `removed` row. Idempotent: a second pass over the same
    /// share writes nothing. The device's key is published into the order first, in
    /// the same transaction, so the rows' signatures have a key row to verify under.
    /// Not entitled on a device that is not the owner's — the rows it would write
    /// read *notEntitled* and change nobody's verdict — so the app calls this for the
    /// orders it owns.
    @discardableResult
    public func reconcileMemberships(
        orderID: Order.ID, members: [Member], localParty: UUID?, at now: Date = Date()
    ) throws -> MembershipReconciliation {
        let signatory = try? signatory()
        let listed = Set(members.filter { !$0.isOwner }.map(\.ref))
        return try queue.write { db in
            if let signatory {
                try Self.publishKeyIfNeeded(orderID: orderID, signatory: signatory, partyRef: localParty, in: db)
            }
            let rows = try Self.memberships(orderID: orderID, in: db)
            var outcome = MembershipReconciliation(mirrored: 0, removed: 0)
            for party in listed.sorted(by: { $0.uuidString < $1.uuidString }) {
                let own = rows.filter { $0.partyRef == party }
                let effective = Membership.effective(among: own)
                guard effective == nil || effective?.role == Membership.Role.removed else { continue }
                let generation = own.filter { $0.role == Membership.Role.removed }.count
                let row = Membership(
                    id: Membership.mirroredID(
                        orderID: orderID, partyRef: party,
                        writerKeyID: signatory?.keyID ?? Signatory.keyIDPrefix, generation: generation),
                    orderID: orderID, partyRef: party, role: Membership.Role.participant,
                    addedAt: now, authorRef: localParty)
                if try Self.insertSigned(table: MembershipRow.tableName, bindings: row.signedBindings,
                                         signatory: signatory, into: db) {
                    outcome.mirrored += 1
                }
            }
            for party in Set(rows.map(\.partyRef)).subtracting(listed).sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let effective = Membership.effective(among: rows.filter { $0.partyRef == party }),
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
    /// participant — as a new row under a caller-held id: a derived id would make
    /// every later assignment collide with the first and vanish. The effective role
    /// is the latest row; earlier rows stay as the role's history.
    @discardableResult
    public func setMembershipRole(
        orderID: Order.ID, partyRef: UUID, role: String, localParty: UUID?, at now: Date = Date()
    ) throws -> Membership {
        let signatory = try? signatory()
        let row = Membership(orderID: orderID, partyRef: partyRef, role: role, addedAt: now, authorRef: localParty)
        try queue.write { db in
            if let signatory {
                try Self.publishKeyIfNeeded(orderID: orderID, signatory: signatory, partyRef: localParty, in: db)
            }
            try Self.insertSigned(table: MembershipRow.tableName, bindings: row.signedBindings,
                                  signatory: signatory, into: db)
        }
        return row
    }
}

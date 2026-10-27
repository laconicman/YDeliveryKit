import Foundation

/// One row of the order's `memberships` table — the share's mirror and a server's
/// source (the app's Schema → "Stage 1"). Append-only and owner-written: the share
/// stays the only grant, the table records who is in and in which role, so a
/// reader can judge entitlement from rows and a host needs nothing reconstructed
/// from CloudKit. Which row is in force is a read-time *selection*, never a dedupe
/// (rule 1): every row stays as the role's history.
public struct Membership: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var orderID: Order.ID
    public var partyRef: UUID
    public var role: String
    public var addedAt: Date
    public var authorRef: UUID?
    public var signingKeyID: String?
    public var signature: String?

    /// The role words — an open vocabulary with named constants.
    public enum Role {
        public static let participant = "participant"
        public static let receiver = "receiver"
        public static let dispatcher = "dispatcher"
        public static let courier = "courier"
        /// Appended when the share no longer lists the party: an append-only table
        /// with no way to say "no longer" would keep a removed participant's
        /// entitlement forever.
        public static let removed = "removed"
    }

    public init(
        id: UUID = UUID(), orderID: Order.ID, partyRef: UUID, role: String, addedAt: Date = Date(),
        authorRef: UUID? = nil, signingKeyID: String? = nil, signature: String? = nil
    ) {
        self.id = id
        self.orderID = orderID
        self.partyRef = partyRef
        self.role = role
        self.addedAt = addedAt
        self.authorRef = authorRef
        self.signingKeyID = signingKeyID
        self.signature = signature
    }

    /// The share-mirrored row's id: one per (order, party, writer key, generation),
    /// so two owner devices reconciling one share each write their own row, both
    /// valid, same role, and a retry is a no-op. `generation` is the number of
    /// `removed` rows the writer sees for the party: a participant who returns after
    /// a removal is a new membership, and a derived id without the count would make
    /// the return collide with the first row and vanish under `INSERT OR IGNORE`.
    /// Two devices converge once they see the same removals.
    public static func mirroredID(
        orderID: Order.ID, partyRef: UUID, writerKeyID: String, generation: Int
    ) -> UUID {
        .derived(namespace: UUID.DerivedNamespace.membership,
                 [orderID.uuidString, partyRef.uuidString, writerKeyID, String(generation)])
    }

    /// The row in force among `rows` — the caller passes only rows that count, which
    /// for roles means rows that read *verified* as the owner's. The latest by
    /// `addedAt`; on an exact tie `removed` dominates, then the smallest id, so every
    /// device derives the same answer and a hash-settled tie between two live roles
    /// is named as the residual it is, settled for good by the owner's next assignment.
    public static func effective(among rows: [Membership]) -> Membership? {
        rows.min { lhs, rhs in
            guard lhs.addedAt == rhs.addedAt else { return lhs.addedAt > rhs.addedAt }
            let lhsRemoved = lhs.role == Role.removed, rhsRemoved = rhs.role == Role.removed
            guard lhsRemoved == rhsRemoved else { return lhsRemoved }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    /// The row in force *as of* a stamp — the latest whose `addedAt` is not after
    /// it. Entitlement is judged as of the row: what a member wrote while a member
    /// stays verified after a removal, and anything dated after the `removed` row
    /// reads *notEntitled* (the app's Collaboration → "Verdicts and entitlement").
    public static func effective(among rows: [Membership], asOf stamp: Date) -> Membership? {
        effective(among: rows.filter { $0.addedAt <= stamp })
    }
}

import Foundation

/// The device's own party under one authority — the row `localIdentity` holds
/// (doc:Schema → "`partyRef`"). `cloudkit:<container>` is the only authority
/// today: `subject` is the CloudKit user record name and `partyRef` the opaque
/// reference derived from it, the same on every device of the account. A server
/// of our own becomes a second authority with its own row; rows and models never
/// learn which one named the party.
public struct LocalIdentity: Hashable, Sendable {
    /// `cloudkit:<containerIdentifier>` · `server:<host>` — the consumer composes it.
    public var authority: String
    /// What the authority calls this device's account — a user record name, a
    /// server's party id.
    public var subject: String
    /// The reference every row uses for this account.
    public var partyRef: UUID
    public var fetchedAt: Date

    public init(authority: String, subject: String, partyRef: UUID, fetchedAt: Date = .now) {
        self.authority = authority
        self.subject = subject
        self.partyRef = partyRef
        self.fetchedAt = fetchedAt
    }
}

extension UUID {
    /// A party reference — `UUIDv5(party ‖ authority ‖ subject)`, derived alike on
    /// every device with no server in between (doc:Design → "Parties, not CloudKit
    /// names"). `authority` is the provider word alone (`cloudkit`, later `apple`,
    /// `google`, `email`, `phone`): a server stores the same UUID as the party's id
    /// and records `(authority, subject)` as one of its identities.
    public static func partyRef(authority: String, subject: String) -> UUID {
        .derived(namespace: UUID.DerivedNamespace.party, authority, subject)
    }
}

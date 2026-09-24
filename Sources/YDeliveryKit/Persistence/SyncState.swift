import Foundation

/// The claims sync's small memory: the journal's opaque position, verbatim, plus
/// whether the one-time history backfill already ran — now rows in `syncStates` and
/// `pendingDiscoveries` rather than a file beside the store. Wiped on the identity
/// boundary: the next token never inherits this account's position.
///
/// The account this state belongs to is `AppDatabase.providerAccountRef`'s business —
/// the value carries the sync position, nothing else.
public nonisolated struct SyncState: Hashable, Sendable {
    /// The provider's next-page token — a JWT on the wire today, but nothing
    /// here decodes it.
    public var cursor: String?
    /// Whether `state: finished` has been paged through once — the deep
    /// membership pass that discovers claims predating the cursor. The flag,
    /// not a timestamp, is what survives.
    public var historyBackfilled: Bool
    /// Claims the journal reported but whose card fetch failed — the cursor
    /// moved past their events, so this queue is the only memory of them
    /// until a retry or a search pass lands the card.
    public var pendingClaimIDs: [String]?

    public init(cursor: String?, historyBackfilled: Bool, pendingClaimIDs: [String]? = nil) {
        self.cursor = cursor
        self.historyBackfilled = historyBackfilled
        self.pendingClaimIDs = pendingClaimIDs
    }
}

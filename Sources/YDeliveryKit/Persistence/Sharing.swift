import CloudKit
import Foundation
import SQLiteData

// The collaboration door, per doc:Collaboration and doc:Schema — a `CKShare`
// rooted at one `orders` row, private only. The policy that cannot drift lives
// at this seam: `publicPermission` is always `.none`, so no call site can ever
// mint a public share; participants join by URL, by name, one order at a time.
extension AppDatabase {

    /// Shares one order — or returns its existing share, since `share(record:)`
    /// reuses the `CKShare` the metadata already knows. The same call therefore
    /// answers "invite someone" and "manage who's in" — the sheet it feeds is
    /// the system's `CloudSharingView`.
    ///
    /// `sendChanges()` runs first: `share(record:)` refuses a record with no
    /// sync metadata, so a just-placed order would otherwise fail with
    /// "record metadata not found" until the next scheduled flush (the upstream
    /// doc's own remedy). On a device that cannot reach iCloud the call throws
    /// and the caller renders it — a share that never happened, not a spinner
    /// that waits for one.
    ///
    /// - Parameters:
    ///   - id: The order to share. It need not exist in the shared tier — an
    ///     unknown id fails at the metadata lookup like an unsynced one, which
    ///     is the honest answer for "nothing to share".
    ///   - title: The share's display name (the recipient sees it in the
    ///     invitation). Composed by the caller — presentation, not state.
    public func shareOrder(id: Order.ID, title: String) async throws -> SharedRecord {
        try await syncEngine.sendChanges()
        return try await syncEngine.share(
            record: OrderRow(id: id, provider: provider)
        ) { share in
            share[CKShare.SystemFieldKey.title] = title
            // Private sharing only — the contract's law (doc:Collaboration →
            // "public sharing stays off"). A participant list, not a link for
            // the internet.
            share.publicPermission = .none
        }
    }

    /// Stops sharing one order — deletes the `CKShare`. A call site that wants
    /// "stop sharing" reaches the same place through `CloudSharingView`'s own
    /// button; that button deletes through UIKit, not this seam, and leaves the
    /// stale cache pointing at the gone share — which is why `.unknownItem`
    /// tolerates here: the server answering "that share does not exist" is the
    /// provably-gone case, truthful to clear whether the deletion was ours or
    /// the sheet's.
    ///
    /// `SyncMetadata.share` is the engine's cache of "which share this record
    /// rides." `SyncEngine.unshare` writes no bookkeeping: it deletes the share
    /// through `modifyRecords` directly, so the zone's change token is not
    /// advanced past the deletion and the *next fetched zone-changes pass*
    /// echoes it back — `SyncEngine.deleteShare` clears the cache then (the
    /// write this mirrors). Clearing eagerly is the same write a fetch cycle
    /// would land moments later, done now because `orderIsShared` answers the
    /// affordance's label and a ghost "manage" button is not worth a sync
    /// round-trip. A later `shareOrder` re-verifies against the cloud anyway
    /// (`.unknownItem` reads as no share), so the column can only be more
    /// truthful.
    public func unshareOrder(id: Order.ID) async throws {
        do {
            try await syncEngine.unshare(record: OrderRow(id: id, provider: provider))
        } catch let error as CKError where error.code == .unknownItem {
            // Provably gone — clearing below is the truth regardless.
        }
        try await queue.write { db in
            try SyncMetadata
                .find(OrderRow(id: id, provider: provider).syncMetadataID)
                .update { $0.share = #bind(nil) }
                .execute(db)
        }
    }

    /// Whether the order rides a share today — the affordance's label ("share"
    /// versus "manage"), not a permission verdict. Reading `SyncMetadata` keeps
    /// the answer in the engine's own book rather than a flag the write path
    /// would have to remember to move.
    public func orderIsShared(_ id: Order.ID) throws -> Bool {
        let metadataID = OrderRow(id: id, provider: provider).syncMetadataID
        return try queue.read { db in
            try SyncMetadata
                .find(metadataID)
                .select(\.share)
                .fetchOne(db) ?? nil != nil
        }
    }

    /// The scene-delegate handoff — a tapped share URL arrives as
    /// `CKShare.Metadata`, the engine accepts it and fetches the shared zone.
    /// Needs no prior start: the accept itself is the CloudKit call; a running
    /// engine merely hastens the fetch of what was just accepted.
    public func acceptShare(metadata: CKShare.Metadata) async throws {
        try await syncEngine.acceptShare(metadata: metadata)
    }
}

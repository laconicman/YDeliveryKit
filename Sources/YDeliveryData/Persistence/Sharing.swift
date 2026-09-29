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
    /// server record, so a just-placed order would otherwise fail until the next
    /// scheduled flush (the upstream doc's own remedy). The refusals this seam
    /// can name are named *here*, before the engine's — its `SharingError` is
    /// private and answers every one of them with the same sentence, "The record
    /// could not be shared." (sqlite-data `CloudKitSharing.swift`), so a caller
    /// that renders the throw would name neither cause nor remedy. Whatever the
    /// pre-checks cannot predict travels up wrapped in ``ShareError/refused(_:)``
    /// — a share that never happened, not a spinner that waits for one.
    ///
    /// - Parameters:
    ///   - id: The order to share. It need not exist in the shared tier — an
    ///     unknown id answers like an unsynced one (``ShareError/notYetInCloud``),
    ///     which is the honest answer for "nothing to share".
    ///   - title: The share's display name (the recipient sees it in the
    ///     invitation). Composed by the caller — presentation, not state.
    /// - Throws: ``ShareError`` — each case names the cause it can know, with the
    ///   remedy in `recoverySuggestion`.
    public func shareOrder(id: Order.ID, title: String) async throws -> SharedRecord {
        if let failure = syncStartFailure {
            throw ShareError(syncStartFailure: failure)
        }
        do {
            try await syncEngine.sendChanges()
            // The engine's own gate, asked first: `share(record:)` throws
            // "record metadata not found" while the row has no server record —
            // still queued, offline, or the device was never signed in (the
            // engine's `start()` swallows a missing account silently).
            guard try reachedCloud(id) else { throw ShareError.notYetInCloud }
            return try await syncEngine.share(
                record: OrderRow(id: id, provider: provider)
            ) { share in
                share[CKShare.SystemFieldKey.title] = title
                // Private sharing only — the contract's law (doc:Collaboration →
                // "public sharing stays off"). A participant list, not a link for
                // the internet.
                share.publicPermission = .none
            }
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.refused(error)
        }
    }

    /// Whether iCloud holds this order's record — the engine's `share(record:)`
    /// answer to "synced or not" is `SyncMetadata.lastKnownServerRecord`, so the
    /// pre-check reads the same column the refusal would.
    private func reachedCloud(_ id: Order.ID) throws -> Bool {
        let metadataID = OrderRow(id: id, provider: provider).syncMetadataID
        return try queue.read { db in
            try SyncMetadata
                .find(metadataID)
                .select(\.lastKnownServerRecord)
                .fetchOne(db) ?? nil != nil
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
    ///
    /// The fetch is repeated here deliberately: the engine's own post-accept
    /// fetch goes through `syncEngines.shared`, which is `nil` until `start()`
    /// completes — a cold launch on a share URL races exactly that, and the
    /// accept would land server-side while the records wait for the next
    /// scheduled pull. `fetchChanges` awaits the engine's `startTask` first, so
    /// calling it always is safe when start is mid-flight; when the engine's
    /// own fetch already ran, this is one bounded extra pass over the same
    /// zones — cheap next to the accept the tap just paid for.
    public func acceptShare(metadata: CKShare.Metadata) async throws {
        try await syncEngine.acceptShare(metadata: metadata)
        try await syncEngine.fetchChanges()
    }

    /// Why an order could not be shared — decided at this seam because the
    /// engine's own refusal is a private type with one fixed sentence for every
    /// cause (sqlite-data `SharingError`; the detail sits in a `debugDescription`
    /// the type does not even conform `CustomDebugStringConvertible` to). A
    /// properly filled error can be passed around and displayed as is — the
    /// author's standing rule — so each case carries `errorDescription` for the
    /// alert's title and `recoverySuggestion` for its remedy.
    public enum ShareError: LocalizedError {
        /// `startSync()` was refused before the engine ran — the iCloud
        /// capability is absent from this build. Not a sign-in problem: no
        /// account state repairs a missing entitlement.
        case noICloudEntitlement
        /// `startSync()` ran and the engine would not start — the stored
        /// ``syncStartFailure``, carried so its own words reach the alert.
        case syncNotStarted(any Error)
        /// `sendChanges()` finished and the order still has no
        /// `lastKnownServerRecord` — it never reached iCloud: queued, offline,
        /// or never signed in. An unknown id lands here too: a row nothing
        /// synced shares nothing.
        case notYetInCloud
        /// The engine's own refusal — `share(record:)` or `sendChanges()`
        /// throwing a CloudKit/network error of its own. Its localized words
        /// are all the public surface it offers.
        case refused(any Error)

        /// Routes the stored start failure: the one case that is a build
        /// property, not a runtime condition, gets its own case — its remedy
        /// differs (no account state fixes an absent entitlement).
        init(syncStartFailure: any Error) {
            self = if syncStartFailure as? SyncStartError == .noICloudEntitlement {
                .noICloudEntitlement
            } else {
                .syncNotStarted(syncStartFailure)
            }
        }

        public var errorDescription: String? {
            switch self {
            case .noICloudEntitlement, .syncNotStarted:
                String(localized: LocalizedStringResource(
                    "Sharing needs iCloud sync.", bundle: .data))
            case .notYetInCloud:
                String(localized: LocalizedStringResource(
                    "This order has not reached iCloud yet.", bundle: .data))
            case .refused:
                String(localized: LocalizedStringResource(
                    "The order could not be shared.", bundle: .data))
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .noICloudEntitlement:
                String(localized: LocalizedStringResource(
                    "This build cannot sync with iCloud.", bundle: .data))
            case .syncNotStarted(let underlying):
                String(localized: LocalizedStringResource(
                    "This install could not start iCloud sync: \(underlying.localizedDescription).",
                    bundle: .data))
            case .notYetInCloud:
                String(localized: LocalizedStringResource(
                    """
                    Sharing needs one successful sync. Make sure this device is signed \
                    in to iCloud and online, then try again in a moment.
                    """,
                    bundle: .data))
            case .refused(let underlying):
                (underlying as? LocalizedError)?.recoverySuggestion
                    ?? underlying.localizedDescription
            }
        }
    }
}

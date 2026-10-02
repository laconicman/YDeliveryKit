import CloudKit
import Foundation
import GRDB
import SQLiteData

// Attribution for the shared tier — the answer to "which account last touched
// this row". CloudKit already records the truth in system fields
// (`creatorUserRecordID`, `lastModifiedUserRecordID`); `SyncMetadata` caches
// those archives locally, so the read is SQL, not a fetch. Names resolve
// through the order's `CKShare` — a lookup-protected participant whose
// identity iCloud hides still carries a stable record-name pseudonym.
extension AppDatabase {

    /// Who CloudKit saw touching one synced row. Every field is optional
    /// because attribution is best-effort by nature: a row that never synced
    /// has no metadata, and iCloud discloses names only when the share's
    /// participant records carry them.
    public struct RecordAuthorship: Hashable, Sendable {
        /// `creatorUserRecordID.recordName` — the account that first wrote the
        /// row. A stable pseudonym; it survives even where names do not.
        public var creatorRecordName: String?
        /// `lastModifiedUserRecordID.recordName` — the account behind the last
        /// synced write. The forgery answer's first half (the signature verdict
        /// is the second: whether the *owner's key* wrote it).
        public var modifierRecordName: String?
        /// The modifier resolved through the share — participant name or the
        /// owner's — `nil` where iCloud does not disclose identity.
        public var modifierName: String?
        /// Whether the modifier is the share's owner — `nil` where no share
        /// exists to ask (a private order's writer is the owner by absence).
        public var modifierIsOwner: Bool?

        /// The empty attribution — nothing synced, nothing discloses.
        public init(
            creatorRecordName: String? = nil, modifierRecordName: String? = nil,
            modifierName: String? = nil, modifierIsOwner: Bool? = nil
        ) {
            self.creatorRecordName = creatorRecordName
            self.modifierRecordName = modifierRecordName
            self.modifierName = modifierName
            self.modifierIsOwner = modifierIsOwner
        }
    }

    /// The provider mirror's authorship — the "recorded by" the detail surface
    /// shows. Non-throwing: absent metadata reads as empty attribution, and the
    /// surfaces that render this degrade by omission, not error UI.
    public func providerStateAuthorship(orderID: Order.ID) -> RecordAuthorship {
        _ = try? syncEngine   // attaches the metadatabase on first use
        return (try? queue.read { db in
            authorship(
                for: OrderProviderStateRow(orderID: orderID).syncMetadataID,
                orderShare: orderShare(orderID, in: db), in: db)
        }) ?? RecordAuthorship()
    }

    /// Per-event authorship for the trail — one entry per stored event row, the
    /// share resolved once. Rows with no server record yet carry an empty
    /// authorship — attribution is absent, not fabricated.
    public func providerEventsAuthorship(
        orderID: Order.ID
    ) -> [ProviderEvent.ID: RecordAuthorship] {
        _ = try? syncEngine
        return (try? queue.read { db in
            let ids: [UUID] = try Row.fetchAll(db, sql: """
                SELECT "id" FROM "providerEvents" WHERE "orderID" = ?
                """, arguments: Self.args([orderID])).map { $0["id"] }
            let share = orderShare(orderID, in: db)
            return ids.reduce(into: [:]) { result, id in
                result[id] = authorship(
                    for: ProviderEventRow(id: id, orderID: orderID).syncMetadataID,
                    orderShare: share, in: db)
            }
        }) ?? [:]
    }

    /// One row's attribution: the archived server record's creator/modifier
    /// record names, plus a display name when the share's participant list
    /// resolves one.
    private func authorship(
        for metadataID: SyncMetadata.ID, orderShare: CKShare?, in db: Database
    ) -> RecordAuthorship {
        let record = (try? SyncMetadata
            .find(metadataID)
            .select(\.lastKnownServerRecord)
            .fetchOne(db)) ?? nil
        guard let record else { return RecordAuthorship() }
        let modifier = record.lastModifiedUserRecordID?.recordName
        let resolved = modifier.flatMap { resolve($0, in: orderShare) }
        return RecordAuthorship(
            creatorRecordName: record.creatorUserRecordID?.recordName,
            modifierRecordName: modifier,
            modifierName: resolved?.name, modifierIsOwner: resolved?.isOwner)
    }

    /// The order's cached share, when the engine has one — the name resolution
    /// table for everything below the root.
    private func orderShare(_ orderID: Order.ID, in db: Database) -> CKShare? {
        (try? SyncMetadata
            .find(OrderRow(id: orderID, provider: provider).syncMetadataID)
            .select(\.share)
            .fetchOne(db)) ?? nil
    }

    /// A record name → (display name, is-owner), or `nil` where no share
    /// exists to ask. The owner's identity is the share's `owner`; participants
    /// match by `userRecordID`. An unresolved name stays `nil` — the UI then
    /// falls back to the record-name pseudonym or a generic participant label.
    private func resolve(
        _ recordName: String, in share: CKShare?
    ) -> (name: String?, isOwner: Bool)? {
        guard let share else { return nil }
        let format: (PersonNameComponents?) -> String? = {
            $0.map { PersonNameComponentsFormatter().string(from: $0) }
        }
        if share.owner.userIdentity.userRecordID?.recordName == recordName {
            return (format(share.owner.userIdentity.nameComponents), true)
        }
        for participant in share.participants
        where participant.userIdentity.userRecordID?.recordName == recordName {
            return (format(participant.userIdentity.nameComponents),
                    participant.role == .owner)
        }
        return (nil, false)
    }
}

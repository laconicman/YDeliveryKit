import CloudKit
import Foundation
import GRDB
import SQLiteData

/// The CloudKit implementation of ``IdentityAuthority`` — with `Sharing.swift`, the
/// only file in the data target that speaks CloudKit (rule 8). It answers one
/// question per key row, *which party does your binding name?*, from the creator
/// stamp CloudKit put on the record and sqlite-data cached in the sync metadata —
/// a trust anchor nobody in a share can forge — and lists an order's members from
/// the root record's cached `CKShare`, merged with the order's membership rows.
/// Nothing above this type sees a record name, a `CKShare` participant or the
/// current-user placeholder; rows carry `partyRef`, models carry `Party`.
public struct CloudKitIdentityAuthority: IdentityAuthority {
    /// The authority word in every `partyRef` derivation and `localIdentity` key.
    public static let authorityKind = "cloudkit"

    private let database: AppDatabase
    private let containerIdentifier: String

    public init(database: AppDatabase, containerIdentifier: String) {
        self.database = database
        self.containerIdentifier = containerIdentifier
    }

    /// The `localIdentity` row's key for a container: `cloudkit:<container>`.
    public static func authorityKey(containerIdentifier: String) -> String {
        "\(authorityKind):\(containerIdentifier)"
    }

    /// The party this device is, once the app has noted the container's user record
    /// name into `localIdentity`; `nil` until then.
    public var localParty: UUID? {
        (try? database.localIdentity(
            authority: Self.authorityKey(containerIdentifier: containerIdentifier)))?.partyRef
    }

    public func binding(of key: ParticipantKey) -> KeyBinding {
        let stamp = (try? database.creatorRecordName(
            recordPrimaryKey: key.id.uuidString.lowercased(),
            recordType: ParticipantKeyRow.tableName)) ?? nil
        let mine = (try? database.signatory().keyID) == key.keyID
        return PartyResolution.binding(
            stampRecordName: stamp, claimedPartyRef: key.partyRef, isMine: mine, localParty: localParty)
    }

    /// Ownership from the zone the root record lives in, then the share: a root that
    /// never synced is this device's; a zone owned by another record name is theirs,
    /// share cached or not; our own zone is private without a share and, with one, the
    /// share's owner resolved like any record name — unresolved while the device does
    /// not know itself.
    public func owner(of orderID: Order.ID) -> Ownership {
        let root = (try? database.rootZone(of: orderID)) ?? nil
        return PartyResolution.ownership(
            zoneOwnerName: root?.ownerName, share: root?.share.map(ShareSummary.init),
            localParty: localParty)
    }

    /// The share's owner and accepted participants, with roles from the membership
    /// rows that count: only rows signed under a key row this authority resolves to the
    /// share's owner (or to this device before any stamp, when this device is the
    /// owner), so a role a participant appended is never reported as the owner's
    /// assignment. A private order lists nobody: its device is its owner.
    public func members(of orderID: Order.ID) -> [Member] {
        guard let share = (try? database.share(of: orderID)) ?? nil else { return [] }
        let summary = ShareSummary(share: share)
        let localParty = localParty
        let counting = (try? database.ownerMemberships(orderID: orderID, authority: self)) ?? []
        return MemberList.merge(summary: summary, memberships: counting, localParty: localParty)
    }
}

extension ShareSummary {
    /// The share reduced to values. Names come only when the person consented to
    /// disclose them (`CKUserIdentity.nameComponents`), formatted the way the rest of
    /// the Kit formats a person: through the components formatter, never hand-joined.
    init(share: CKShare) {
        let formatter = PersonNameComponentsFormatter()
        func name(of participant: CKShare.Participant) -> String? {
            guard let components = participant.userIdentity.nameComponents else { return nil }
            let formatted = formatter.string(from: components)
            return formatted.isEmpty ? nil : formatted
        }
        ownerRecordName = share.owner.userIdentity.userRecordID?.recordName
        ownerName = name(of: share.owner)
        participants = share.participants
            .filter { $0.role != .owner }
            .map { participant in
                Participant(
                    recordName: participant.userIdentity.userRecordID?.recordName,
                    displayName: name(of: participant),
                    accepted: participant.acceptanceStatus == .accepted,
                    canWrite: participant.permission == .readWrite)
            }
    }
}

extension AppDatabase {
    /// A read with the engine's metadatabase attached: constructing the engine is what
    /// attaches it, so the engine is asked for first — outside any write transaction,
    /// never inside one (the parked branch's `_ = try? syncEngine` inside a write was
    /// the trap).
    func withMetadatabase<T>(_ read: (Database) throws -> T) throws -> T {
        _ = try syncEngine
        return try queue.read(read)
    }

    /// The record name CloudKit stamped as the creator of one synced row, from the
    /// sync metadata's cached server record; `nil` before the row has been to the
    /// server. On the current user's own records this is the current-user
    /// placeholder, which ``PartyResolution`` resolves to the local party.
    func creatorRecordName(recordPrimaryKey: String, recordType: String) throws -> String? {
        try withMetadatabase { db in
            let record = try SyncMetadata
                .where { $0.recordPrimaryKey.eq(recordPrimaryKey) && $0.recordType.eq(recordType) }
                .select(\.lastKnownServerRecord)
                .fetchOne(db) ?? nil
            return record?.creatorUserRecordID?.recordName
        }
    }

    /// The order's cached `CKShare`, present on the owner's and every participant's
    /// device once the root has been shared or the share accepted; `nil` for a
    /// private order.
    func share(of orderID: Order.ID) throws -> CKShare? {
        try rootZone(of: orderID)?.share
    }

    /// The zone the order's root record lives in — its owner's record name, the
    /// current-user placeholder for our own zone — and the cached share, when any;
    /// `nil` for a root that never synced.
    func rootZone(of orderID: Order.ID) throws -> (ownerName: String, share: CKShare?)? {
        try withMetadatabase { db in
            let root = SyncMetadata.find(OrderRow(id: orderID, provider: provider).syncMetadataID)
            guard let ownerName = try root.select(\.ownerName).fetchOne(db) else { return nil }
            return (ownerName, try root.select(\.share).fetchOne(db) ?? nil)
        }
    }
}

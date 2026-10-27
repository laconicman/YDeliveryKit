import Foundation

/// The pure half of the CloudKit identity authority: what a creator stamp, a row's
/// own claim and the device's knowledge of itself resolve to. Kept free of CloudKit
/// types so it can be tested exhaustively; the authority feeds it what it read.
enum PartyResolution {
    /// The record name CloudKit stamps on the current user's own records in place of
    /// their real one — `CKCurrentUserDefaultName`, spelled here so this file needs
    /// no CloudKit import. Device-relative: it names whoever is signed in *here*.
    static let currentUserDefaultName = "__defaultOwner__"

    /// The party a record name resolves to: the current-user placeholder is the local
    /// party, known or not; any other name derives the party every device derives.
    /// `nil` only for the placeholder on a device that does not know itself yet — a
    /// case the caller must not paper over with a fabricated party.
    static func party(forRecordName recordName: String, localParty: UUID?) -> UUID? {
        guard recordName != currentUserDefaultName else { return localParty }
        return UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: recordName)
    }

    /// Who owns an order, from the one fact that is there before any share is cached:
    /// the owner of the zone the root record lives in (the app's Collaboration →
    /// "Verdicts and entitlement", role resolution). A root that never synced is
    /// local — nothing of anyone else's can be there. A zone owned by another record
    /// name is theirs, share cached or not; our own zone is private without a share,
    /// and with one the share's owner resolves like any record name — the placeholder
    /// is this device, unresolved while it does not know itself (review, PR #47).
    static func ownership(zoneOwnerName: String?, share: ShareSummary?, localParty: UUID?) -> Ownership {
        guard let zoneOwnerName else { return .local }
        guard zoneOwnerName == currentUserDefaultName else {
            return .party(UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: zoneOwnerName))
        }
        guard let share else { return .local }
        return share.ownerRef(localParty: localParty).map(Ownership.party) ?? .unresolved
    }

    /// Which party a key row's binding names (the app's Collaboration → "Keys" →
    /// *Trust*): the creator stamp resolves to a party — a real record name, or the
    /// current-user placeholder on a device whose own party is known; the row's own
    /// `partyRef`, when present, must agree, and a disagreement is a conflict; a row
    /// with no stamp yet is unbound for everyone except the device that holds the
    /// private key, which recognises its own fingerprint.
    static func binding(
        stampRecordName: String?, claimedPartyRef: UUID?, isMine: Bool, localParty: UUID?
    ) -> KeyBinding {
        guard let stampRecordName,
              let stamped = party(forRecordName: stampRecordName, localParty: localParty)
        else { return isMine ? .mine : .none }
        if let claimedPartyRef, claimedPartyRef != stamped { return .conflict }
        return .party(stamped)
    }
}

/// The share as the authority read it, reduced to values: the owner, the
/// participants and what each may do. No CloudKit type crosses this line (rule 8).
struct ShareSummary: Hashable, Sendable {
    struct Participant: Hashable, Sendable {
        var recordName: String?
        var displayName: String?
        var accepted: Bool
        var canWrite: Bool
    }

    var ownerRecordName: String?
    var ownerName: String?
    var participants: [Participant]

    /// The owner's party as this device resolves it; `nil` when the share names the
    /// owner by the current-user placeholder and the device does not know itself yet.
    func ownerRef(localParty: UUID?) -> UUID? {
        ownerRecordName.flatMap { PartyResolution.party(forRecordName: $0, localParty: localParty) }
    }
}

/// The merge of a share summary with the order's membership rows into the members
/// the authority lists. The share is the grant and the binary "in" or "out"; a
/// membership row's role wins over that binary status, which is why only rows that
/// count — signed under a key resolved to the owner — may be passed in; a party the
/// share no longer lists is not a member whatever its rows say, and the reconcile
/// appends its `removed` row at the next pass. Record names resolve through
/// ``PartyResolution``, so the current-user placeholder is the local party here as
/// it is on a key binding; a member the device cannot yet resolve is left out rather
/// than listed under a party nobody else derives.
enum MemberList {
    static func merge(summary: ShareSummary?, memberships: [Membership], localParty: UUID?) -> [Member] {
        guard let summary else { return [] }
        var members: [Member] = []
        if let ownerRef = summary.ownerRef(localParty: localParty) {
            members.append(Member(ref: ownerRef, canWrite: true, displayName: summary.ownerName, isOwner: true))
        }
        for participant in summary.participants where participant.accepted {
            guard let recordName = participant.recordName,
                  let ref = PartyResolution.party(forRecordName: recordName, localParty: localParty)
            else { continue }
            let effective = Membership.effective(among: memberships.filter { $0.partyRef == ref })
            let role = effective.flatMap { $0.role == Membership.Role.removed ? nil : $0.role }
            members.append(Member(
                ref: ref, role: role, canWrite: participant.canWrite,
                displayName: participant.displayName))
        }
        return members
    }
}

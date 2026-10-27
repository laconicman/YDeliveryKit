import Foundation

/// The pure half of the CloudKit identity authority: what a creator stamp, a row's
/// own claim and the device's knowledge of itself resolve to. Kept free of CloudKit
/// types so it can be tested exhaustively; the authority feeds it what it read.
enum PartyResolution {
    /// The record name CloudKit stamps on the current user's own records in place of
    /// their real one — `CKCurrentUserDefaultName`, spelled here so this file needs
    /// no CloudKit import.
    static let currentUserDefaultName = "__defaultOwner__"

    /// Which party a key row's binding names (the app's Collaboration → "Keys" →
    /// *Trust*): the creator stamp resolves to a party — a real record name, or the
    /// current-user placeholder on a device whose own party is known; the row's own
    /// `partyRef`, when present, must agree, and a disagreement is a conflict; a row
    /// with no stamp yet is unbound for everyone except the device that holds the
    /// private key, which recognises its own fingerprint.
    static func binding(
        stampRecordName: String?, claimedPartyRef: UUID?, isMine: Bool, localParty: UUID?
    ) -> KeyBinding {
        let stamped: UUID?
        switch stampRecordName {
        case nil:
            stamped = nil
        case currentUserDefaultName?:
            stamped = localParty
        case let recordName?:
            stamped = UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: recordName)
        }
        guard let stamped else { return isMine ? .mine : .none }
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
}

/// The merge of a share summary with the order's membership rows into the members
/// the authority lists. The share is the grant and the binary "in" or "out"; a
/// membership row's role wins over that binary status; a party the share no longer
/// lists is not a member whatever its rows say — the reconcile appends its
/// `removed` row at the next pass.
enum MemberList {
    static func merge(summary: ShareSummary?, memberships: [Membership]) -> [Member] {
        guard let summary else { return [] }
        var members: [Member] = []
        if let ownerRecordName = summary.ownerRecordName {
            members.append(Member(
                ref: UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: ownerRecordName),
                canWrite: true, displayName: summary.ownerName, isOwner: true))
        }
        for participant in summary.participants where participant.accepted {
            guard let recordName = participant.recordName else { continue }
            let ref = UUID.partyRef(authority: CloudKitIdentityAuthority.authorityKind, subject: recordName)
            let effective = Membership.effective(among: memberships.filter { $0.partyRef == ref })
            let role = effective.flatMap { $0.role == Membership.Role.removed ? nil : $0.role }
            members.append(Member(
                ref: ref, role: role, canWrite: participant.canWrite,
                displayName: participant.displayName))
        }
        return members
    }
}

import Foundation

/// What a reader concludes about one signed row (the app's Collaboration →
/// "Verdicts and entitlement"). A verdict is a read-time value beside the model,
/// never a field on it, never persisted and never in Codable output (rule 5); a
/// failed verdict renders as a warning beside the data it concerns and never
/// refuses, drops or hides the row (rule 6).
public enum Verdict: Hashable, Sendable {
    /// The signature verifies under a key row whose binding names `author`, and
    /// `author` may write this row kind for this leg.
    case verified(author: Party)
    /// Written before signing existed for this order: NULL signature and no
    /// `participantKeys` row for the order. Quiet.
    case legacy
    /// NULL signature on an order that has key rows: a write that bypassed the
    /// signing path, or a device that could not reach its key. Warned.
    case unsigned
    /// A signature is present and does not verify, or `authorRef` disagrees with
    /// the key row's binding. Warned.
    case invalid
    /// The named key row is missing, or its binding names a different party than
    /// it claims. Warned.
    case untrustedKey
    /// The key row has no binding yet and is not this device's. Quiet, labelled
    /// "not yet verifiable".
    case unverifiable
    /// A correct signature by a trusted key whose party may not write this row
    /// kind — a participant's order event, a courier's event on another leg.
    case notEntitled(author: Party)

    /// Whether the verdict renders as a warning beside the row.
    public var isWarned: Bool { warning != nil }

    /// The sentence a warned verdict renders, in the design system's feedback role;
    /// `nil` for the quiet verdicts. The writer's name, when the authority discloses
    /// one, is the caller's to add beside it.
    public var warning: LocalizedStringResource? {
        switch self {
        case .verified, .legacy, .unverifiable:
            nil
        case .unsigned:
            LocalizedStringResource("This row did not pass through the signing path", bundle: .data)
        case .invalid:
            LocalizedStringResource("The signature does not match the row", bundle: .data)
        case .untrustedKey:
            LocalizedStringResource("The signing key is not trusted", bundle: .data)
        case .notEntitled:
            LocalizedStringResource("Written by a participant who may not write this", bundle: .data)
        }
    }
}

/// What a projection's check against the signed facts yields (the app's Schema →
/// "Derived integrity"): the mirror's status against the latest verified
/// status-bearing event, the stored route against the latest verified digest.
public enum IntegrityVerdict: Hashable, Sendable {
    case consistent
    /// The projection differs from the one expected value the signed history names.
    case disagrees(expected: String)
    /// No verified event carries the fact to check against.
    case noSignedHistory
}

/// A value a read hands back together with the verdict on the row it came from.
public struct Attested<Value: Sendable>: Sendable {
    public var value: Value
    public var verdict: Verdict

    public init(value: Value, verdict: Verdict) {
        self.value = value
        self.verdict = verdict
    }
}

/// Who is accountable for a row: a party, never a device and never a CloudKit
/// name (rule 8). `ref` is the opaque `partyRef` every row carries; the name
/// comes from the authority at render time and is never stored in a signed row.
public struct Party: Hashable, Sendable {
    /// The `partyRef`; `nil` only for legacy and unsigned rows.
    public var ref: UUID?
    /// From the authority, when the person consented to disclose it.
    public var displayName: String?
    public var role: Role

    public enum Role: Hashable, Sendable {
        case owner
        /// A share participant — `kind` is the membership row's word
        /// (`participant`, `receiver`, `dispatcher`).
        case member(kind: String)
        /// A share participant with read permission only: a member who may write
        /// nothing, whatever role a row names.
        case reader
        /// The courier the effective `legs` row names for `legRef`.
        case courier(legRef: UUID)
        /// A party the read places but who holds no role as of the row's stamp — dated
        /// past the owner's `removed` row. Reads *notEntitled*, never *unverifiable*.
        case unknown
    }

    public init(ref: UUID?, displayName: String? = nil, role: Role) {
        self.ref = ref
        self.displayName = displayName
        self.role = role
    }
}

/// One published device key: a `participantKeys` row as a value (the app's
/// Schema → "Stage 1"). Self-signed over every column but `signature`; its binding
/// is what the identity authority resolves to a party.
public struct ParticipantKey: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var orderID: Order.ID
    /// The writer's party; `nil` until the device knows itself.
    public var partyRef: UUID?
    public var keyID: String
    /// The X9.63 public key, base64.
    public var publicKey: String
    public var bindingKind: String
    /// The server's attestation, server mode only; `nil` and signed as NULL under
    /// the CloudKit binding, whose proof is the server stamp in the sync metadata.
    public var bindingProof: String?
    public var bindingKeyID: String?
    public var boundAt: Date?
    public var addedAt: Date
    public var signature: String?

    /// The binding kinds a key row names — an open vocabulary with named constants.
    public enum BindingKind {
        public static let cloudkit = "cloudkit"
        public static let server = "server"
    }

    public init(
        id: UUID, orderID: Order.ID, partyRef: UUID? = nil, keyID: String, publicKey: String,
        bindingKind: String, bindingProof: String? = nil, bindingKeyID: String? = nil,
        boundAt: Date? = nil, addedAt: Date, signature: String? = nil
    ) {
        self.id = id
        self.orderID = orderID
        self.partyRef = partyRef
        self.keyID = keyID
        self.publicKey = publicKey
        self.bindingKind = bindingKind
        self.bindingProof = bindingProof
        self.bindingKeyID = bindingKeyID
        self.boundAt = boundAt
        self.addedAt = addedAt
        self.signature = signature
    }
}

/// The identity authority's answer to "which party does this key row's binding
/// name?"
public enum KeyBinding: Hashable, Sendable {
    /// The binding names this party.
    case party(UUID)
    /// This device's own key, recognised by its fingerprint before any binding.
    case mine
    /// No binding yet — the row has not been stamped or attested.
    case none
    /// The binding names a party other than the row's own `partyRef` claims.
    case conflict
}

/// A member of an order as the authority lists it — the share's owner and
/// participants in CloudKit mode — merged with the order's `memberships` rows.
public struct Member: Hashable, Sendable {
    public var ref: UUID
    /// The effective membership role, or `nil` before the owner's device has
    /// reconciled one.
    public var role: String?
    public var canWrite: Bool
    public var displayName: String?
    /// The share's owner — the party that writes the order and its memberships.
    public var isOwner: Bool

    public init(ref: UUID, role: String? = nil, canWrite: Bool, displayName: String? = nil,
                isOwner: Bool = false) {
        self.ref = ref
        self.role = role
        self.canWrite = canWrite
        self.displayName = displayName
        self.isOwner = isOwner
    }
}

/// Who owns an order, as the authority answers it.
public enum Ownership: Hashable, Sendable {
    /// A private order: this device is its owner.
    case local
    /// A shared order whose owner the authority resolved to a party.
    case party(UUID)
    /// A shared order whose owner cannot be resolved yet — the share names the owner
    /// by the current-user placeholder and this device does not know itself. Nobody is
    /// the owner for trust purposes until it does: no row counts for a role, and the
    /// reconcile writes nothing (review, PR #47).
    case unresolved
}

/// The seam that keeps CloudKit out of the rows (rule 8): `CKCurrentUserDefaultName`,
/// record names and `CKShare` participants exist only inside an implementation of
/// this protocol. One implementation arrives with the key rows; a server's later.
public protocol IdentityAuthority: Sendable {
    /// The party this device is, once the authority has told it.
    var localParty: UUID? { get }
    func binding(of key: ParticipantKey) -> KeyBinding
    func owner(of orderID: Order.ID) -> Ownership
    func members(of orderID: Order.ID) -> [Member]
}

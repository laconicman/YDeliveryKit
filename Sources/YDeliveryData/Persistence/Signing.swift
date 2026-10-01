import CryptoKit
import Foundation
import GRDB

// Record integrity for the owner-written provider mirror (doc:Collaboration →
// "Provider state is signed by the device that wrote it"). A read-write share
// participant can edit any row's bytes — record permissions are per-record, not
// per-table — so the signature is what distinguishes *the owner's device wrote
// this* from *someone with write access typed it*. The key is an Ed25519 pair
// (`Curve25519.Signing`), private half in the iCloud Keychain so every owner
// device signs and no participant ever can; the public half rides on the order
// root as `ownerSigningKey`.

/// The read-side answer to "who wrote this row" — attached to the models the
/// read paths hand back (`Order.signatureStatus`, `RoutePoint.signatureStatus`,
/// `ProviderEvent.signatureStatus`). Rendered, never enforced: a bad verdict
/// warns beside the data, it does not hide it.
///
/// The ordering matters: `keyChanged` dominates everything else (a rotated key
/// makes every row verdict moot), and `unsigned` only exists on a signing-active
/// order — `ensureSigning` backfills signatures when the key is stamped, so an
/// unsigned row under a known key is a write that never passed through the
/// owner's sign path.
public enum SignatureVerdict: String, Codable, Hashable, Sendable {
    /// The order carries no `ownerSigningKey` — pre-signing data, a share
    /// accepted before the feature shipped, or a store with no key custody.
    /// Quiet by design: unsigned ≠ forged (doc:Schema).
    case notSigned
    /// The signature verifies against the order's pinned key. Quiet.
    case verified
    /// The order's key is known but this row has no signature — a write that
    /// bypassed the owner's signing path. Warned.
    case unsigned
    /// A signature is present but does not verify — the row's bytes changed
    /// after signing, or were written by a different key. Warned.
    case invalid
    /// The order's `ownerSigningKey` differs from the key pinned on first
    /// sight (TOFU) — either a legitimate cross-device rotation or a claimed
    /// key that was never the owner's. Warned.
    case keyChanged
}

/// One Ed25519 keypair's working half — the private key for the signing side,
/// the public key for verification. `rawRepresentation` is the 32-byte seed form
/// both sides serialize to (base64 for the TEXT columns, raw for the Keychain
/// item).
public struct Signatory: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    /// A fresh random keypair.
    public init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    /// Rehydrates a stored private key — the Keychain item's bytes.
    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// The public key, raw 32-byte form — what `orders.ownerSigningKey` carries
    /// (base64'd) and what readers verify against.
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// The private half's serialized form — what the Keychain item stores.
    /// Internal: nothing outside the persistence layer touches private-key bytes.
    var privateKeyData: Data { privateKey.rawRepresentation }

    /// What `signingKeyID` stamps: algorithm + payload format + a key
    /// fingerprint, so a rotated key and a future format change are both legible
    /// from the column alone.
    public var keyID: String {
        "ed25519.v1."
            + SHA256.hash(data: publicKey).prefix(4)
                .map { String(format: "%02x", $0) }.joined()
    }

    public func sign(_ payload: Data) throws -> Data {
        try privateKey.signature(for: payload)
    }

    /// Verifies `signature` (base64) over `payload` against `publicKeyBase64`.
    /// Every decode failure — bad base64, wrong-length key, short signature —
    /// is simply *not verified*: the caller renders `.invalid`, it does not
    /// crash or discard the row.
    public static func verify(
        payload: Data, signatureBase64: String, publicKeyBase64: String
    ) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: payload)
    }
}

/// The byte stream a signature actually covers. Canonicalization is the whole
/// job: two devices must derive identical bytes for identical rows, so the form
/// is fixed here — a domain separator, the table name, then each signed column
/// in declaration order as `name 0x00 tag value`. Signature columns are absent
/// from the column lists by construction — a row's signature never signs itself.
///
/// Value tags: `0` NULL (no bytes follow), `1` TEXT (utf8 length-prefixed),
/// `2` INTEGER (int64 big-endian), `3` REAL (IEEE-754 bitPattern big-endian).
/// Reading the stored `DatabaseValue`, not the Swift value the writer held, is
/// deliberate: the signature covers the row as persisted — REAL-epoch dates,
/// lowercase uuid TEXT — not the caller's representation of it.
enum CanonicalPayload {
    /// `orderProviderStates` — every column but the signature pair.
    static let providerStateColumns = [
        "orderID", "claimID", "corpClientID", "status", "providerStatus",
        "providerDetail", "tariff", "price", "currency",
        "courierName", "courierVehicle", "etaMinutes",
        "dueAt", "finishedAt", "providerObservedAt", "mirroredAt",
    ]
    /// `providerEvents` — every column but the signature pair.
    static let providerEventColumns = [
        "id", "orderID", "providerEventID", "at", "kind",
        "providerStatus", "detail", "source",
    ]
    /// `routeStops` — the whole row, sender fields included: an address a
    /// participant rewrites is a worse forgery than a faked visit.
    static let routeStopColumns = [
        "id", "orderID", "position", "role", "latitude", "longitude", "address",
        "building", "entrance", "floor", "apartment", "intercom",
        "contactName", "contactGivenName", "contactFamilyName",
        "contactPhone", "contactPhoneExtension",
        "visitStatus", "visitedAt", "expectedVisitAt",
    ]

    /// The payload for one stored row. `columns` names the signed surface;
    /// each is read through `row[...]` so a column missing from the SELECT
    /// traps loudly rather than silently signing NULL.
    static func payload(table: String, columns: [String], row: Row) -> Data {
        var payload = Data("YDX1".utf8)
        payload.append(Data(table.utf8))
        payload.append(0)
        for column in columns {
            payload.append(Data(column.utf8))
            payload.append(0)
            let value: DatabaseValue = row[column]
            switch value.storage {
            case .null:
                payload.append(0)
            case .string(let string):
                payload.append(1)
                let bytes = Data(string.utf8)
                payload.append(contentsOf: UInt32(bytes.count).bigEndianBytes)
                payload.append(bytes)
            case .int64(let int):
                payload.append(2)
                payload.append(contentsOf: int.bigEndianBytes)
            case .double(let double):
                payload.append(3)
                payload.append(contentsOf: double.bitPattern.bigEndianBytes)
            case .blob(let data):
                payload.append(4)
                payload.append(contentsOf: UInt32(data.count).bigEndianBytes)
                payload.append(data)
            }
        }
        return payload
    }
}

extension FixedWidthInteger {
    /// Big-endian byte form for the canonical payload — deterministic across
    /// platforms regardless of host endianness.
    fileprivate var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

import CryptoKit
import Foundation
import GRDB

/// The byte stream a signature covers (the app's Collaboration → "The canonical
/// payload"). Canonicalisation is the whole job: the writer and every verifier —
/// another device, a server over Postgres — must derive identical bytes for one
/// row, so the form is fixed here: a version tag, the table name, then each signed
/// column in its frozen order as `name 0x00 tag value`. Signature columns are
/// absent from every column list by construction: a row's signature never signs
/// itself, and the writer's identity (`signingKeyID`) travels beside the payload.
///
/// Both sides call one function over `DatabaseValue`s: the writer over the values
/// it is about to bind, normalised exactly as ``AppDatabase/args(_:)`` normalises
/// them; the verifier over the values read back from the row. Same bytes by
/// construction, and the same bytes a verifier produces from the same typed
/// columns elsewhere — no write ever re-reads stored bytes to sign them (rule 3).
///
/// Tags: `0` NULL (no bytes follow) · `1` TEXT (u32 big-endian byte length, UTF-8)
/// · `2` INTEGER (i64 big-endian) · `3` REAL (IEEE-754 bit pattern, big-endian)
/// · `4` BLOB (u32 big-endian length, bytes).
public enum CanonicalPayload {
    /// The payload version. Adding a column to a signed table is a new version
    /// (`YDX3`, `p256.v3.`); rows keep verifying under the version their key id names.
    public static let version = "YDX2"

    /// The frozen v2 column lists, per table, in signing order. Unused by any
    /// writer until the signed facts land; the lists are the contract and belong
    /// with the version they name.
    public static let signedColumns: [String: [String]] = [
        ParticipantKeyRow.tableName: [
            "id", "orderID", "partyRef", "keyID", "publicKey", "bindingKind",
            "bindingProof", "bindingKeyID", "boundAt", "addedAt",
        ],
        MembershipRow.tableName: ["id", "orderID", "partyRef", "role", "addedAt", "authorRef"],
        OrderEventRow.tableName: [
            "id", "orderID", "legRef", "providerEventID", "providerRevision", "at", "kind",
            "providerStatus", "detail", "source", "routeDigest", "authorRef",
        ],
        OrderMessageRow.tableName: [
            "id", "orderID", "sentAt", "kind", "text", "attachmentRef", "authorRef",
        ],
        OrderAttachmentRow.tableName: [
            "id", "orderID", "kind", "caption", "byteSize", "createdAt", "dataHash", "authorRef",
        ],
        OrderRatingRow.tableName: [
            "id", "orderID", "legRef", "authorRef", "subjectKind", "subjectRef",
            "subjectLabel", "score", "comment", "at",
        ],
    ]

    /// The sender-authored stop columns the route digest covers, in `routeStops`'s
    /// declaration order. Visit columns are provider truth and excluded; stop ids are
    /// identity, not content, and excluded.
    public static let routeDigestColumns = [
        "position", "role", "latitude", "longitude", "address",
        "building", "entrance", "floor", "apartment", "intercom",
        "contactName", "contactGivenName", "contactFamilyName",
        "contactPhone", "contactPhoneExtension",
    ]

    /// The payload for one row: `columns` and `values` pair up in order.
    public static func payload(table: String, columns: [String], values: [DatabaseValue]) -> Data {
        precondition(columns.count == values.count,
                     "a canonical payload pairs every column with one value")
        var payload = Data(version.utf8)
        payload.append(Data(table.utf8))
        payload.append(0)
        for (column, value) in zip(columns, values) {
            payload.append(Data(column.utf8))
            payload.append(0)
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

    /// The write side: the values a statement binds, as the database will store
    /// them — the same normalisation as ``AppDatabase/args(_:)`` (UUIDs lowercase
    /// TEXT; everything else through its `DatabaseValueConvertible` form).
    public static func databaseValues(_ bindings: [(any DatabaseValueConvertible)?]) -> [DatabaseValue] {
        bindings.map { value in
            ((value as? UUID)?.uuidString.lowercased() ?? value)?.databaseValue ?? .null
        }
    }

    /// The read side: the stored values of `columns`, in order. A column the SELECT
    /// did not fetch is a programmer error, never a silent NULL in a signed payload.
    public static func values(from row: Row, columns: [String]) -> [DatabaseValue] {
        columns.map { column in
            precondition(row.hasColumn(column), "the SELECT did not fetch \(column)")
            return row[column]
        }
    }

    /// `hex(SHA-256(...))` over the route as the sender authored it: every stop in
    /// position order, each as a canonical payload of ``routeDigestColumns`` under
    /// the `routeStops` table name, concatenated. Carried by a `placed` event over
    /// the route as sent and by every `sighting` over the route as the provider
    /// reported it.
    public static func routeDigest(for stops: [RoutePoint]) -> String {
        routeDigest(stopValues: stops.enumerated().map { index, point in
            databaseValues(senderAuthoredBindings(of: point, at: index))
        })
    }

    /// The same digest over stored rows — one value list per stop, in position
    /// order, each read with ``values(from:columns:)`` over ``routeDigestColumns``.
    public static func routeDigest(stopValues: [[DatabaseValue]]) -> String {
        var hasher = SHA256()
        for values in stopValues {
            hasher.update(data: payload(
                table: RouteStopRow.tableName, columns: routeDigestColumns, values: values))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The sender-authored columns of one stop as the writer binds them — one
    /// list shared by the `routeStops` insert and the digest, so the two cannot
    /// drift: `position` is the index, `role` falls back to the index's word the way
    /// the insert always has, absent address parts and contacts bind NULL.
    static func senderAuthoredBindings(
        of point: RoutePoint, at index: Int
    ) -> [(any DatabaseValueConvertible)?] {
        [
            index,
            point.role?.rawValue ?? (index == 0 ? RoutePoint.Role.pickup.rawValue
                                                : RoutePoint.Role.dropoff.rawValue),
            point.latitude, point.longitude, point.address,
            point.addressParts?.building,
            point.addressParts?.entrance,
            point.addressParts?.floor,
            point.addressParts?.apartment,
            point.addressParts?.intercom,
            point.contactName,
            point.contactGivenName,
            point.contactFamilyName,
            point.contactPhone,
            point.contactPhoneExtension,
        ]
    }
}

extension FixedWidthInteger {
    /// Big-endian byte form for the canonical payload — deterministic across
    /// platforms regardless of host endianness.
    fileprivate var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

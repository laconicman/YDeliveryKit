import Foundation
import GRDB

// Key publication and the key rows' read (the app's Collaboration → "Keys" →
// *Publication*): a `participantKeys` row per (order, device key, binding), inserted
// with `INSERT OR IGNORE` inside the first signed write of that device into that
// order, self-signed over every column it carries.

extension ParticipantKey {
    /// `UUIDv5(participantKey ‖ orderID ‖ keyID ‖ bindingKind)` — one binding
    /// statement, so the same key published later under a server binding is a new
    /// row, not a collision.
    public static func derivedID(orderID: Order.ID, keyID: String, bindingKind: String) -> UUID {
        .derived(namespace: UUID.DerivedNamespace.participantKey,
                 [orderID.uuidString, keyID, bindingKind])
    }

    /// The frozen v2 list's values, as the row binds and stores them.
    var signedBindings: [(any DatabaseValueConvertible)?] {
        [id, orderID, partyRef, keyID, publicKey, bindingKind, bindingProof, bindingKeyID,
         boundAt?.timeIntervalSince1970, addedAt.timeIntervalSince1970]
    }

    /// Whether the row's self-signature verifies under its own published key, and the
    /// key id is that key's: a rewritten `publicKey`, a rewritten proof, or a key id
    /// that names another key all read false. Verified from the row's own values,
    /// which store and read back exactly (epoch seconds as REAL).
    public var selfSignatureIsValid: Bool {
        guard let signature,
              let keyData = Data(base64Encoded: publicKey),
              keyID == Signatory.keyID(publicKeyX963: keyData)
        else { return false }
        let payload = CanonicalPayload.payload(
            table: ParticipantKeyRow.tableName,
            columns: CanonicalPayload.signedColumns[ParticipantKeyRow.tableName] ?? [],
            values: CanonicalPayload.databaseValues(signedBindings))
        return Signatory.verify(payload: payload, signatureBase64: signature, publicKeyBase64: publicKey)
    }
}

extension AppDatabase {
    /// Publishes the device's key into the order under the given binding if no row
    /// exists yet. Called inside the same transaction as the first signed write; the
    /// signatory is the caller's, resolved before the transaction. Returns whether a
    /// row was written.
    @discardableResult
    static func publishKeyIfNeeded(
        orderID: Order.ID, signatory: Signatory, partyRef: UUID?,
        bindingKind: String = ParticipantKey.BindingKind.cloudkit, addedAt: Date = Date(),
        in db: Database
    ) throws -> Bool {
        let key = ParticipantKey(
            id: ParticipantKey.derivedID(orderID: orderID, keyID: signatory.keyID, bindingKind: bindingKind),
            orderID: orderID, partyRef: partyRef, keyID: signatory.keyID,
            publicKey: signatory.publicKeyBase64, bindingKind: bindingKind, addedAt: addedAt)
        return try insertSigned(
            table: ParticipantKeyRow.tableName, bindings: key.signedBindings,
            signatory: signatory, keyIDColumn: nil, into: db)
    }

    /// The order's published keys, oldest first.
    public func participantKeys(orderID: Order.ID) throws -> [ParticipantKey] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "participantKeys" WHERE "orderID" = ?
                ORDER BY "addedAt", "id"
                """, arguments: Self.args([orderID])).map(Self.participantKey)
        }
    }

    private static func participantKey(_ row: Row) -> ParticipantKey {
        ParticipantKey(
            id: row["id"], orderID: row["orderID"], partyRef: row["partyRef"],
            keyID: row["keyID"], publicKey: row["publicKey"], bindingKind: row["bindingKind"],
            bindingProof: row["bindingProof"], bindingKeyID: row["bindingKeyID"],
            boundAt: (row["boundAt"] as Double?).map { Date(timeIntervalSince1970: $0) },
            addedAt: Date(timeIntervalSince1970: row["addedAt"]),
            signature: row["signature"])
    }
}

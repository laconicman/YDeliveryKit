import CloudKit
import Foundation
import GRDB
import os
import SQLiteData

// Signing and verification for the owner-written provider surface
// (doc:Collaboration → "Provider state is signed by the device that wrote it").
// Every provider-truth row lands signed inside the same write transaction as its
// content; every read verifies and attaches a ``SignatureVerdict`` — rendered as
// a warning, never a refusal, never a discarded row.
extension AppDatabase {

    /// The key this device signs owner rows under — resolved once per database
    /// (the Keychain is fast, but every write funnels here). `nil` when the
    /// consumer gave no `signingService` or the store refused — both read as
    /// "write unsigned" rather than a failed write.
    var signatory: Signatory? {
        signingKeyCell.withLock { cell in
            if let cell { return cell }
            let resolved = signingKeyStore?.signatory()
            cell = .some(resolved)
            return resolved
        }
    }

    // MARK: - Write side

    /// Whether this device's writes own the order's zone — the signer-side gate
    /// that keeps a participant's app from stamping its key (or signing) under a
    /// foreign share. Sync metadata absent reads as *local*: a foreign zone can
    /// only arrive through the engine, and no metadata means none arrived. On a
    /// share, the current user's participant role decides — owner devices all
    /// read `.owner`; a share whose participant row is unresolved fails closed
    /// to *not* ours rather than claiming a key we cannot prove. Read outside
    /// any write transaction — `syncEngine` attaches the metadatabase lazily and
    /// must not be re-entered mid-write.
    func isLocallyOwnedZone(orderID: Order.ID) -> Bool {
        _ = try? syncEngine
        return (try? queue.read { db in
            let share = try SyncMetadata
                .find(OrderRow(id: orderID, provider: provider).syncMetadataID)
                .select(\.share)
                .fetchOne(db) ?? nil
            return share.map { $0.currentUserParticipant?.role == .owner } ?? true
        }) ?? true
    }

    /// The order-level half of every provider-tier write, inside the write
    /// transaction: stamp `ownerSigningKey` where it is NULL, rotate it where a
    /// local order advertises a key this device no longer holds (iCloud Keychain
    /// mid-convergence), and re-sign every child row either way a change lands —
    /// CryptoKit's Ed25519 is randomized, so a re-sign writes fresh bytes that
    /// still verify. The own-device pin follows the writer's key so a rotation
    /// we performed never warns on the device that performed it.
    static func ensureSigning(orderID: Order.ID, signatory: Signatory, in db: Database) throws {
        let local = signatory.publicKey.base64EncodedString()
        let stored: String? = try String.fetchOne(db, sql: """
            SELECT "ownerSigningKey" FROM "orders" WHERE "id" = ?
            """, arguments: Self.args([orderID]))
        guard stored != local else { return }
        try db.execute(sql: """
            UPDATE "orders" SET "ownerSigningKey" = ?
            WHERE "id" = ? AND ("ownerSigningKey" IS NULL OR "ownerSigningKey" != ?)
            """, arguments: Self.args([local, orderID, local]))
        guard db.changesCount > 0 else { return }
        try resignChildren(orderID: orderID, signatory: signatory, in: db)
        try pinOrderKey(orderID: orderID, publicKey: local, in: db)
    }

    /// Sign (or re-sign) every signed-surface child of the order: mirror,
    /// stops, events. Called when the order's key first stamps — existing
    /// pre-signing rows were owner-authored too — and on rotation, where every
    /// old signature is invalid under the new key.
    static func resignChildren(orderID: Order.ID, signatory: Signatory, in db: Database) throws {
        try signMirror(orderID: orderID, signatory: signatory, in: db)
        try signStops(orderID: orderID, signatory: signatory, in: db)
        try signEvents(orderID: orderID, signatory: signatory, in: db)
    }

    /// Re-reads the mirror row and signs what is stored — the signature covers
    /// persisted bytes, not the writer's in-memory values.
    static func signMirror(orderID: Order.ID, signatory: Signatory, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM "orderProviderStates" WHERE "orderID" = ?
            """, arguments: Self.args([orderID])) else { return }
        let signature = try signatory.sign(CanonicalPayload.payload(
            table: OrderProviderStateRow.tableName,
            columns: CanonicalPayload.providerStateColumns, row: row))
        try db.execute(sql: """
            UPDATE "orderProviderStates" SET "signature" = ?, "signingKeyID" = ?
            WHERE "orderID" = ?
            """, arguments: Self.args([
                signature.base64EncodedString(), signatory.keyID, orderID]))
    }

    /// Every stop of the order, re-signed in place — called after the
    /// delete-and-rewrite a `recordOrder` lands, and by ``resignChildren``.
    static func signStops(orderID: Order.ID, signatory: Signatory, in db: Database) throws {
        let ids: [UUID] = try Row.fetchAll(db, sql: """
            SELECT "id" FROM "routeStops" WHERE "orderID" = ?
            """, arguments: Self.args([orderID])).map { $0["id"] }
        for id in ids { try signStop(id: id, signatory: signatory, in: db) }
    }

    /// Every event of the order — ``recordProviderEvent`` signs the row it just
    /// wrote instead; this is the backfill/rotation path's whole-history pass.
    static func signEvents(orderID: Order.ID, signatory: Signatory, in db: Database) throws {
        let ids: [UUID] = try Row.fetchAll(db, sql: """
            SELECT "id" FROM "providerEvents" WHERE "orderID" = ?
            """, arguments: Self.args([orderID])).map { $0["id"] }
        for id in ids { try signEvent(id: id, signatory: signatory, in: db) }
    }

    static func signStop(id: UUID, signatory: Signatory, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM "routeStops" WHERE "id" = ?
            """, arguments: Self.args([id])) else { return }
        let signature = try signatory.sign(CanonicalPayload.payload(
            table: RouteStopRow.tableName,
            columns: CanonicalPayload.routeStopColumns, row: row))
        try db.execute(sql: """
            UPDATE "routeStops" SET "signature" = ?, "signingKeyID" = ?
            WHERE "id" = ?
            """, arguments: Self.args([
                signature.base64EncodedString(), signatory.keyID, id]))
    }

    static func signEvent(id: UUID, signatory: Signatory, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM "providerEvents" WHERE "id" = ?
            """, arguments: Self.args([id])) else { return }
        let signature = try signatory.sign(CanonicalPayload.payload(
            table: ProviderEventRow.tableName,
            columns: CanonicalPayload.providerEventColumns, row: row))
        try db.execute(sql: """
            UPDATE "providerEvents" SET "signature" = ?, "signingKeyID" = ?
            WHERE "id" = ?
            """, arguments: Self.args([
                signature.base64EncodedString(), signatory.keyID, id]))
    }

    /// The device's own TOFU record — written when this device stamps or rotates
    /// the key, so the writer never warns on a change it performed itself.
    static func pinOrderKey(orderID: Order.ID, publicKey: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO "ownerKeyPins" ("orderRef", "publicKey", "firstSeenAt")
            VALUES (?, ?, ?)
            """, arguments: Self.args([orderID, publicKey, Date.now.timeIntervalSince1970]))
    }

    // MARK: - Read side

    /// Every pinned owner key — the table is device-tier and small (one row per
    /// order ever seen signed), so the whole map reads once per list read.
    static func ownerKeyPins(in db: Database) throws -> [UUID: String] {
        try Row.fetchAll(db, sql: """
            SELECT "orderRef", "publicKey" FROM "ownerKeyPins"
            """).reduce(into: [:]) { pins, row in
            let orderID: UUID = row["orderRef"]
            pins[orderID] = row["publicKey"]
        }
    }

    /// The verdict for one signed-surface row. `payload` is a closure because
    /// the canonical bytes are needed only when a signature exists to check —
    /// the common `.unsigned`/`.notSigned`/`.keyChanged` paths never build it.
    static func signedRowVerdict(
        ownerKey: String?, pin: String?, signature: String?,
        payload: () -> Data
    ) -> SignatureVerdict {
        guard let ownerKey else { return .notSigned }
        if let pin, pin != ownerKey { return .keyChanged }
        guard let signature else { return .unsigned }
        return Signatory.verify(
            payload: payload(), signatureBase64: signature,
            publicKeyBase64: ownerKey) ? .verified : .invalid
    }

    /// First-sight pinning, collected during a read and written after it — the
    /// pin table is device-local, so this write leaves no CloudKit footprint.
    /// Failure is not the read's failure: a dropped pin only means the next
    /// read treats the same key as first-sight again, which is the pin's honest
    /// answer anyway.
    func pinFirstSight(_ pins: [(orderID: UUID, publicKey: String)]) {
        guard !pins.isEmpty else { return }
        try? queue.write { db in
            for pin in pins {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO "ownerKeyPins"
                      ("orderRef", "publicKey", "firstSeenAt")
                    VALUES (?, ?, ?)
                    """, arguments: Self.args([
                        pin.orderID, pin.publicKey, Date.now.timeIntervalSince1970]))
            }
        }
    }
}

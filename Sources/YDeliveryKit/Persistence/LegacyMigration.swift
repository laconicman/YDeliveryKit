import CryptoKit
import Foundation
import GRDB
import OSLog

/// First launch under the new stack: the three JSON stores become tables. The
/// substrate's rule applies — **bytes are never destroyed**: each source is renamed
/// `*.migrated-<timestamp>.json` in place only after its import commits, an
/// undecodable one is rescued to `*.corrupted-<timestamp>-<id>.json`, and a source
/// whose insert fails stays put for next launch's retry. Derived child ids make that
/// retry idempotent (doc:Schema → Migration).
nonisolated enum LegacyMigration {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "YDelivery", category: "persistence")

    private static var markerTimestamp: String {
        String(Int(Date.now.timeIntervalSince1970))
    }

    /// The `claims-sync.json` shape — `SyncStateStore.State` as the file store wrote
    /// it. Kept private: the file is legacy, the type exists only to decode it.
    private struct FileSyncState: Codable {
        var cursor: String?
        var historyBackfilled: Bool
        var pendingClaimIDs: [String]?
    }

    /// Runs each source independently — one bad file must not hold the others
    /// hostage. A source that throws leaves its file untouched and logs loudly;
    /// the store still opens, and next launch retries. The account/provider pair is
    /// the consumer's: migrated rows attach to whichever account the host named.
    static func run(in directory: URL, db: DatabaseQueue,
                    providerAccountRef: String, provider: String) {
        migrateOrders(in: directory, db: db, provider: provider)
        migrateSyncState(in: directory, db: db, providerAccountRef: providerAccountRef)
        migratePlaces(in: directory, db: db)
    }

    private static func migrateOrders(in directory: URL, db: DatabaseQueue,
                                      provider: String) {
        migrate(file: "orders.json", in: directory, decode: {
            try JSONDecoder().decode([Order].self, from: $0)
        }, insert: { orders, db in
            var drafts: [Order] = []
            for order in orders {
                // A draft has no provider existence — the shared tier refuses it
                // and `orderDrafts` is skeletal (no route columns), so the refused
                // rows separate into a durable sibling file instead.
                if order.status == .draft { drafts.append(order); continue }
                try AppDatabase.insertMigrating(order, provider: provider, into: db)
            }
            return drafts.isEmpty ? nil : drafts
        }, db: db)
    }

    private static func migratePlaces(in directory: URL, db: DatabaseQueue) {
        migrate(file: "places.json", in: directory, decode: {
            try JSONDecoder().decode([SavedPlace].self, from: $0)
        }, insert: { places, db in
            for place in places {
                try insert(place, into: db)
            }
            return nil
        }, db: db)
    }

    private static func migrateSyncState(in directory: URL, db: DatabaseQueue,
                                         providerAccountRef: String) {
        migrate(file: "claims-sync.json", in: directory, decode: {
            try JSONDecoder().decode(FileSyncState.self, from: $0)
        }, insert: { state, db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO "syncStates"
                  ("providerAccountRef", "journalCursor", "historyBackfilled")
                VALUES (?, ?, ?)
                """, arguments: AppDatabase.args([
                    providerAccountRef, state.cursor,
                    state.historyBackfilled ? 1 : 0,
                ]))
            for claimID in state.pendingClaimIDs ?? [] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO "pendingDiscoveries"
                      ("id", "providerAccountRef", "claimID", "firstSeenAt")
                    VALUES (?, ?, ?, ?)
                    """, arguments: AppDatabase.args([
                        UUID.derived(
                            namespace: UUID.DerivedNamespace.pendingDiscovery,
                            providerAccountRef, claimID),
                        providerAccountRef, claimID,
                        Date.now.timeIntervalSince1970,
                    ]))
            }
            return nil
        }, db: db)
    }

    /// One source's decode → transaction → rename. `INSERT OR IGNORE` on derived keys
    /// is what makes a crash in the commit→rename window safe to retry. `insert`
    /// returns the rows the substrate *refused* — drafts today — which are separated
    /// into a durable `<stem>.pending-*.json` sibling before the source renames, so
    /// the committed file leaves rotation entirely (no replay, no resurrection of
    /// deleted rows) while the refused bytes stay findable for a future migration.
    private static func migrate<Payload: Encodable>(
        file name: String,
        in directory: URL,
        decode: (Data) throws -> Payload,
        insert: (Payload, Database) throws -> Payload?,
        db: DatabaseQueue
    ) {
        let source = directory.appendingPathComponent(name)
        // Absent reads as empty — but *unreadable* is not absent: a file that exists
        // and won't read must not silently migrate nothing. The generic catch below
        // logs it and leaves the file, so next launch retries.
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            let data = try Data(contentsOf: source)
            let payload = try decode(data)
            let remainder = try db.write { db in try insert(payload, db) }
            if let remainder {
                // Content-named, not timestamped: an interruption after this write
                // re-derives the same file on retry — a pending artifact must be
                // idempotent, or every reopen accumulates duplicates. A tag match
                // with *different* bytes is the (astronomically rare) collision —
                // keep the existing file and sidecar the new one, never overwrite.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]  // stable bytes — the name must be
                let remainderData = try encoder.encode(remainder)
                let tag = Insecure.SHA1.hash(data: remainderData)
                    .prefix(6).map { String(format: "%02x", $0) }.joined()
                var pending = source.deletingPathExtension()
                    .appendingPathExtension("pending-\(tag).json")
                if let existing = try? Data(contentsOf: pending), existing == remainderData {
                    // Already separated — identical content needs no second write.
                } else {
                    if FileManager.default.fileExists(atPath: pending.path) {
                        pending = source.deletingPathExtension().appendingPathExtension(
                            "pending-\(tag)-\(UUID().uuidString.prefix(8)).json")
                    }
                    try remainderData.write(to: pending, options: .atomic)
                }
                logger.error("\(name) held rows the substrate refuses — separated to \(pending.lastPathComponent, privacy: .public) until those rows have a home")
            }
            let migrated = source.deletingPathExtension()
                .appendingPathExtension(
                    "migrated-\(markerTimestamp)-\(UUID().uuidString.prefix(8)).json")
            try FileManager.default.moveItem(at: source, to: migrated)
        } catch is DecodingError {
            // Undecodable is not unimported-forever: rescue the bytes beside the
            // source (collision-proof sidecar, the substrate's convention) and let
            // the store open — a corrupt file blocking migration would wedge the
            // app on every launch.
            let rescued = source.deletingPathExtension()
                .appendingPathExtension(
                    "corrupted-\(markerTimestamp)-\(UUID().uuidString.prefix(8)).json")
            do {
                try FileManager.default.moveItem(at: source, to: rescued)
                logger.error("Migrated \(name, privacy: .public) was undecodable; bytes rescued to \(rescued.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Migrated \(name, privacy: .public) was undecodable and could not be rescued: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.error("Migrating \(name, privacy: .public) failed; source left in place for retry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func insert(_ place: SavedPlace, into db: Database) throws {
        let p = place.point
        try db.execute(sql: """
            INSERT OR IGNORE INTO "savedPlaces"
              ("id", "name", "kind",
               "latitude", "longitude", "address",
               "entrance", "floor", "apartment", "intercom",
               "contactName", "contactGivenName", "contactFamilyName",
               "contactPhone", "contactPhoneExtension")
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: AppDatabase.args([
                place.id, place.name, place.kind.rawValue,
                p.latitude, p.longitude, p.address,
                p.addressParts?.entrance,
                p.addressParts?.floor,
                p.addressParts?.apartment,
                p.addressParts?.intercom,
                p.contactName,
                p.contactGivenName,
                p.contactFamilyName,
                p.contactPhone,
                p.contactPhoneExtension,
            ]))
    }
}

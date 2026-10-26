import Foundation
import GRDB
import OSLog

/// Schema epoch 2's one-time import (doc:Schema → "Epoch 2"): a store from before
/// the epoch (`ydelivery.sqlite`) found beside the new file is copied into it, table
/// by table, on the new store's first open — then marked in place as imported.
/// The substrate's rule holds throughout: **bytes are never destroyed**. The old
/// file is renamed, never deleted; a file that will not open as a database is
/// rescued aside as `*.corrupted-<t>-<id>`; a copy that fails leaves the old file
/// untouched for the next open's retry.
///
/// The copy is a plain row copy, not a replay through the typed writers: the old
/// rows were written by those writers and already hold their invariants, and a
/// writer re-run would stamp `lastActivityAt` and `mirroredAt` with today and drop
/// the mirror columns the flat `Order` does not carry. Only the shape changes —
/// `providerEvents` lands in `orderEvents`, every other table keeps its name — and
/// the columns the epoch added stay NULL: an imported event is history nobody
/// signed, which reads as *legacy*, the truth. Column sets intersect at run time
/// (the new table's columns that the old one has), so a store from any pre-epoch
/// shape imports whatever it carries.
///
/// Every insert is `INSERT OR IGNORE` by primary key, so a run interrupted between
/// the copy's commit and the rename is safe to repeat: the second pass writes
/// nothing. No sync metadata is copied — the new store's engine starts from
/// nothing and uploads the imported rows as its own, into the new container.
enum EpochImport {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "YDelivery", category: "persistence")

    /// Old table → new table. Everything not listed keeps its name.
    private static let renamedTables: [String: String] = [
        "providerEvents": OrderEventRow.tableName,
    ]

    /// Parents before children — `PRAGMA foreign_keys` may be on for the
    /// connection, and a child inserted before its parent would be refused.
    /// What a column absent from an older shape means: the defaults the pre-epoch
    /// ALTER list carried (0.4.15 `columnMigrations`), relocated. A store last
    /// opened before one of these columns existed imports as the column's default;
    /// a required column neither side knows aborts the import rather than guess.
    private static let absentColumnDefaults: [String: [String: String]] = [
        SavedPlaceRow.tableName: ["pinned": "0"],
        OrderDraftRow.tableName: [
            "proCourier": "0", "toDoor": "1", "thermobag": "0", "loaders": "0", "comment": "''",
        ],
        DraftItemRow.tableName: ["quantity": "1", "currency": "''"],
    ]

    /// The one backfill the ALTER list carried, kept: a store from before
    /// `orderCustomFields.carrier` learns each value's carrier from its definition.
    private static let carrierBackfill = """
        UPDATE "\(OrderCustomFieldRow.tableName)" SET "carrier" = (
          SELECT "carrier" FROM "\(CustomFieldDefinitionRow.tableName)"
          WHERE "\(CustomFieldDefinitionRow.tableName)"."id"
            = "\(OrderCustomFieldRow.tableName)"."fieldRef")
        WHERE "carrier" IS NULL
        """

    struct UnknownRequiredColumn: Error, CustomStringConvertible {
        let table: String
        let column: String
        var description: String {
            "\(table).\(column) is required by the epoch's shape, absent from the old store, and has no default"
        }
    }

    private static let importOrder: [String] = [
        OrderRow.tableName,
        OrderProviderStateRow.tableName, OrderOptionsRow.tableName,
        RouteStopRow.tableName, OrderItemRow.tableName, OrderCustomFieldRow.tableName,
        OrderEventRow.tableName,
        OrderMessageRow.tableName, OrderAttachmentRow.tableName, AttachmentBlobRow.tableName,
        ProviderAccountRow.tableName, OrderPrivateStateRow.tableName,
        SavedPlaceRow.tableName, CustomFieldDefinitionRow.tableName,
        ParcelTemplateRow.tableName, ParcelTemplateItemRow.tableName,
        SyncStateRow.tableName, PendingDiscoveryRow.tableName, PendingAcceptanceRow.tableName,
        OrderDraftRow.tableName, DraftStopRow.tableName, DraftItemRow.tableName,
        DraftCustomFieldRow.tableName,
    ]

    /// What one run did — returned for the tests and logged for the field.
    struct Outcome: Equatable {
        var rowsCopied: Int
        var tablesCopied: Int
        var markedAside: [String]
    }

    /// Runs the import if a pre-epoch store exists in `directory`; a no-op otherwise.
    /// A copy failure is thrown, so the open that called this fails and the store is
    /// unavailable for the launch — the consumer renders "could not look" rather than
    /// acting on an empty history (review, PR #45) — while the old file stays where
    /// the next open retries from. Two cases are rescued instead of thrown: a file
    /// that is not a database is marked aside, since it can never import; and a
    /// rename that fails after a successful copy is logged, since the next open's
    /// `INSERT OR IGNORE` re-copy is a no-op and tries the rename again.
    @discardableResult
    static func run(in directory: URL, into db: DatabaseQueue) throws -> Outcome? {
        let legacy = directory.appendingPathComponent(AppDatabase.legacyFilename)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let copied: Outcome
        do {
            copied = try copy(from: legacy, into: db)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            // Not a database: rescue the bytes aside, collision-proof, and let the
            // store open — a file that can never import must not wedge every launch.
            let rescued = legacy.appendingPathExtension(
                "corrupted-\(Self.marker())")
            do {
                try FileManager.default.moveItem(at: legacy, to: rescued)
                logger.error("Epoch import: \(AppDatabase.legacyFilename, privacy: .public) is not a database; bytes rescued to \(rescued.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Epoch import: \(AppDatabase.legacyFilename, privacy: .public) is not a database and could not be rescued: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        } catch {
            logger.error("Epoch import failed; the store is unavailable this launch and the old store stays for the next open's retry: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let marked: [String]
        do {
            marked = try markImported(in: directory)
        } catch {
            logger.error("Epoch import copied \(copied.rowsCopied) rows but could not mark the old store aside; the next open re-copies (a no-op) and retries the mark: \(error.localizedDescription, privacy: .public)")
            marked = []
        }
        logger.notice("Epoch import: \(copied.rowsCopied) rows in \(copied.tablesCopied) tables from \(AppDatabase.legacyFilename, privacy: .public); marked \(marked.count) files")
        return Outcome(rowsCopied: copied.rowsCopied, tablesCopied: copied.tablesCopied,
                       markedAside: marked)
    }

    /// The row copy, one transaction on the new store. The old store is opened
    /// read-only: sqlite-data's triggers are temporary (connection-scoped), so the
    /// file carries none, and nothing here writes to it anyway.
    private static func copy(from legacy: URL, into db: DatabaseQueue) throws -> Outcome {
        var configuration = Configuration()
        configuration.readonly = true
        let old = try DatabaseQueue(path: legacy.path, configuration: configuration)
        let oldTables = try old.read { db in
            try String.fetchAll(db, sql: """
                SELECT "name" FROM sqlite_master WHERE "type" = 'table'
                """)
        }
        let oldColumns = try old.read { db -> [String: [String]] in
            var columns: [String: [String]] = [:]
            for table in oldTables {
                columns[table] = try String.fetchAll(db, sql: """
                    SELECT "name" FROM pragma_table_info(?)
                    """, arguments: [table])
            }
            return columns
        }
        var rowsCopied = 0
        var tablesCopied = 0
        try db.write { new in
            for table in importOrder {
                let source = renamedTables.first { $0.value == table }?.key ?? table
                guard let sourceColumns = oldColumns[source] else { continue }
                let target = try Row.fetchAll(new, sql: """
                    SELECT "name", "notnull", "dflt_value" FROM pragma_table_info(?)
                    """, arguments: [table])
                var columns: [String] = []  // copied from the old store
                var filled: [(column: String, literal: String)] = []  // required, absent there
                for info in target {
                    let name: String = info["name"]
                    guard !sourceColumns.contains(name) else {
                        columns.append(name)
                        continue
                    }
                    let required: Bool = info["notnull"]
                    let hasDefault = (info["dflt_value"] as String?) != nil
                    guard required, !hasDefault else { continue }
                    guard let literal = absentColumnDefaults[table]?[name] else {
                        throw UnknownRequiredColumn(table: table, column: name)
                    }
                    filled.append((name, literal))
                }
                guard !columns.isEmpty else { continue }
                let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
                let insertColumns = (columns + filled.map(\.column))
                    .map { "\"\($0)\"" }.joined(separator: ", ")
                let insertValues = (columns.map { _ in "?" } + filled.map(\.literal))
                    .joined(separator: ", ")
                let rows = try old.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT \(quoted) FROM "\(source)"
                        """)
                }
                for row in rows {
                    let values = columns.map { row[$0] as DatabaseValue }
                    try new.execute(sql: """
                        INSERT OR IGNORE INTO "\(table)" (\(insertColumns)) VALUES (\(insertValues))
                        """, arguments: StatementArguments(values))
                    rowsCopied += new.changesCount
                }
                tablesCopied += 1
            }
            try new.execute(sql: carrierBackfill)
        }
        return Outcome(rowsCopied: rowsCopied, tablesCopied: tablesCopied, markedAside: [])
    }

    /// Renames the old store and its sidecars — the `-wal`/`-shm` journals and the
    /// hidden sqlite-data metadatabase beside it (`.ydelivery.metadata-<container>
    /// .sqlite`, with journals of its own) — as `<name>.imported-<t>-<id>`. Files
    /// already marked (`.imported-`, `.corrupted-`) are left alone, so a retried
    /// run never re-marks a mark.
    private static func markImported(in directory: URL) throws -> [String] {
        let stem = (AppDatabase.legacyFilename as NSString).deletingPathExtension
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let marker = marker()
        var marked: [String] = []
        for name in names.sorted() {
            let isStore = name.hasPrefix(AppDatabase.legacyFilename)
            let isMetadatabase = name.hasPrefix(".\(stem).metadata")
            guard isStore || isMetadatabase,
                  !name.contains(".imported-"), !name.contains(".corrupted-")
            else { continue }
            let source = directory.appendingPathComponent(name)
            let target = directory.appendingPathComponent("\(name).imported-\(marker)")
            try FileManager.default.moveItem(at: source, to: target)
            marked.append(target.lastPathComponent)
        }
        return marked
    }

    /// Timestamp plus a short random tag — collision-proof, the substrate's sidecar
    /// convention.
    private static func marker() -> String {
        "\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    }
}

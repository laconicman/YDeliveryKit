import Foundation

nonisolated extension AppDatabase {
    /// The contract's DDL, verbatim from doc:Schema — table names interpolate from the
    /// `@Table` declarations so the two can never drift. `SyncEngine` reads FK-ness
    /// from `PRAGMA foreign_key_list`: `*Ref` columns carry no `REFERENCES` clause,
    /// which is the one-FK share arithmetic made visible. Dates are REAL epoch
    /// seconds, booleans INTEGER — STRICT tables make that a checked fact.
    static let ddl = """
        CREATE TABLE IF NOT EXISTS "\(OrderRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "createdAt" REAL NOT NULL,
          "providerAccountRef" TEXT,
          "provider" TEXT NOT NULL,
          "lastActivityAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderProviderStateRow.tableName)" (
          "orderID" TEXT PRIMARY KEY NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "claimID" TEXT, "corpClientID" TEXT, "status" TEXT NOT NULL,
          "providerStatus" TEXT, "providerDetail" TEXT,
          "tariff" TEXT, "price" TEXT, "currency" TEXT,
          "courierName" TEXT, "courierVehicle" TEXT, "etaMinutes" INTEGER,
          "dueAt" REAL, "finishedAt" REAL,
          "providerObservedAt" REAL, "mirroredAt" REAL NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderOptionsRow.tableName)" (
          "orderID" TEXT PRIMARY KEY NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "proCourier" INTEGER NOT NULL, "toDoor" INTEGER NOT NULL,
          "thermobag" INTEGER NOT NULL, "loaders" INTEGER NOT NULL,
          "due" REAL, "comment" TEXT NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(RouteStopRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
          "address" TEXT NOT NULL,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT,
          "visitStatus" TEXT, "visitedAt" REAL, "expectedVisitAt" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderItemRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL,
          "pickupStopRef" TEXT, "dropoffStopRef" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderCustomFieldRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "name" TEXT NOT NULL, "value" TEXT NOT NULL,
          "carrier" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(ProviderEventRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "providerEventID" INTEGER, "at" REAL NOT NULL,
          "kind" TEXT NOT NULL, "providerStatus" TEXT,
          "detail" TEXT, "source" TEXT NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderMessageRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "sentAt" REAL NOT NULL, "kind" TEXT NOT NULL,
          "text" TEXT, "attachmentRef" TEXT, "authorHint" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderAttachmentRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "kind" TEXT NOT NULL, "caption" TEXT, "byteSize" INTEGER,
          "createdAt" REAL NOT NULL, "authorHint" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(AttachmentBlobRow.tableName)" (
          "attachmentID" TEXT PRIMARY KEY NOT NULL
            REFERENCES "\(OrderAttachmentRow.tableName)"("id") ON DELETE CASCADE,
          "data" BLOB NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(ProviderAccountRow.tableName)" (
          "key" TEXT PRIMARY KEY NOT NULL,
          "provider" TEXT NOT NULL, "corpClientID" TEXT,
          "displayLabel" TEXT, "firstSeenAt" REAL, "lastSeenAt" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderPrivateStateRow.tableName)" (
          "orderID" TEXT PRIMARY KEY NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "personalNote" TEXT, "pinned" INTEGER NOT NULL,
          "lastSeenActivityAt" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(SavedPlaceRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
          "address" TEXT NOT NULL,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(CustomFieldDefinitionRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
          "choicesJSON" TEXT NOT NULL,
          "isOptional" INTEGER NOT NULL, "isShownByDefault" INTEGER NOT NULL,
          "carrier" TEXT NOT NULL, "position" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(SyncStateRow.tableName)" (
          "providerAccountRef" TEXT PRIMARY KEY NOT NULL,
          "journalCursor" TEXT, "historyBackfilled" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(PendingDiscoveryRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "providerAccountRef" TEXT NOT NULL, "claimID" TEXT NOT NULL,
          "firstSeenAt" REAL NOT NULL, "lastAttemptAt" REAL,
          UNIQUE("providerAccountRef", "claimID")
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(PendingAcceptanceRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "providerAccountRef" TEXT NOT NULL, "claimID" TEXT,
          "orderRef" TEXT, "createdAt" REAL NOT NULL,
          "lastCheckedAt" REAL, "state" TEXT NOT NULL,
          "attempt" INTEGER NOT NULL DEFAULT 1
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderDraftRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "createdAt" REAL NOT NULL,
          "proCourier" INTEGER NOT NULL, "toDoor" INTEGER NOT NULL,
          "thermobag" INTEGER NOT NULL, "loaders" INTEGER NOT NULL,
          "due" REAL, "comment" TEXT NOT NULL, "chosenTariff" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(DraftStopRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL
            REFERENCES "\(OrderDraftRow.tableName)"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL, "longitude" REAL, "address" TEXT,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(DraftItemRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL
            REFERENCES "\(OrderDraftRow.tableName)"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL,
          "pickupStopRef" TEXT, "dropoffStopRef" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(DraftCustomFieldRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "draftID" TEXT NOT NULL
            REFERENCES "\(OrderDraftRow.tableName)"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "value" TEXT
        ) STRICT;
        """

    /// Columns added after the schema's birth — `CREATE TABLE IF NOT EXISTS`
    /// creates today's shape but never alters yesterday's table, so each late
    /// column gets an idempotent `ADD COLUMN` checked against `table_info`
    /// (SQLite can't add a column to a STRICT table conditionally; the pragma
    /// check is the guard). (table, column, type, backfill) quadruples, applied
    /// in order — `backfill` runs once, only when the column was just added.
    static let columnMigrations: [(table: String, column: String, type: String,
                                  backfill: String?)] = [
        (OrderProviderStateRow.tableName, "courierName", "TEXT", nil),
        (OrderProviderStateRow.tableName, "courierVehicle", "TEXT", nil),
        (OrderProviderStateRow.tableName, "etaMinutes", "INTEGER", nil),
        (OrderCustomFieldRow.tableName, "carrier", "TEXT", """
            UPDATE "orderCustomFields" SET "carrier" = (
              SELECT "carrier" FROM "customFieldDefinitions"
              WHERE "customFieldDefinitions"."id" = "orderCustomFields"."fieldRef")
            """),
        (RouteStopRow.tableName, "visitStatus", "TEXT", nil),
        (RouteStopRow.tableName, "visitedAt", "REAL", nil),
        (RouteStopRow.tableName, "expectedVisitAt", "REAL", nil),
        (PendingAcceptanceRow.tableName, "attempt", "INTEGER NOT NULL DEFAULT 1", nil),
        // YD-16 — the draft tier grows real columns. NOT NULL additions carry
        // `DEFAULT` only to satisfy ALTER's grammar; the tables were skeletal and
        // never written, so no row can ever read the defaults.
        (OrderDraftRow.tableName, "proCourier", "INTEGER NOT NULL DEFAULT 0", nil),
        (OrderDraftRow.tableName, "toDoor", "INTEGER NOT NULL DEFAULT 1", nil),
        (OrderDraftRow.tableName, "thermobag", "INTEGER NOT NULL DEFAULT 0", nil),
        (OrderDraftRow.tableName, "loaders", "INTEGER NOT NULL DEFAULT 0", nil),
        (OrderDraftRow.tableName, "due", "REAL", nil),
        (OrderDraftRow.tableName, "comment", "TEXT NOT NULL DEFAULT ''", nil),
        (OrderDraftRow.tableName, "chosenTariff", "TEXT", nil),
        (DraftStopRow.tableName, "latitude", "REAL", nil),
        (DraftStopRow.tableName, "longitude", "REAL", nil),
        (DraftStopRow.tableName, "address", "TEXT", nil),
        (DraftStopRow.tableName, "entrance", "TEXT", nil),
        (DraftStopRow.tableName, "floor", "TEXT", nil),
        (DraftStopRow.tableName, "apartment", "TEXT", nil),
        (DraftStopRow.tableName, "intercom", "TEXT", nil),
        (DraftStopRow.tableName, "contactName", "TEXT", nil),
        (DraftStopRow.tableName, "contactGivenName", "TEXT", nil),
        (DraftStopRow.tableName, "contactFamilyName", "TEXT", nil),
        (DraftStopRow.tableName, "contactPhone", "TEXT", nil),
        (DraftStopRow.tableName, "contactPhoneExtension", "TEXT", nil),
        (DraftItemRow.tableName, "quantity", "INTEGER NOT NULL DEFAULT 1", nil),
        (DraftItemRow.tableName, "weightKg", "REAL", nil),
        (DraftItemRow.tableName, "cost", "TEXT", nil),
        (DraftItemRow.tableName, "currency", "TEXT NOT NULL DEFAULT ''", nil),
        (DraftItemRow.tableName, "sizeLengthCm", "REAL", nil),
        (DraftItemRow.tableName, "sizeWidthCm", "REAL", nil),
        (DraftItemRow.tableName, "sizeHeightCm", "REAL", nil),
        (DraftItemRow.tableName, "pickupStopRef", "TEXT", nil),
        (DraftItemRow.tableName, "dropoffStopRef", "TEXT", nil),
    ]
}

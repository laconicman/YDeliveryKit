import Foundation

extension AppDatabase {
    /// The contract's DDL, verbatim from doc:Schema — table names interpolate from the
    /// `@Table` declarations so the two can never drift. `SyncEngine` reads FK-ness
    /// from `PRAGMA foreign_key_list`: `*Ref` columns carry no `REFERENCES` clause,
    /// which is the one-FK share arithmetic made visible. Dates are REAL epoch
    /// seconds, booleans INTEGER — STRICT tables make that a checked fact.
    ///
    /// Schema epoch 2 (doc:Schema → "Primary keys"): no shared-tier primary key
    /// carries `ON CONFLICT REPLACE`. A colliding plain `INSERT` used to rewrite the
    /// existing row silently — invisible to sync (REPLACE fires no delete trigger and
    /// never bumps `userModificationTime`, YD-34) and, under signing, a way to replace
    /// a signed row wholesale. Every writer states its own policy in the statement:
    /// `INSERT OR IGNORE` for facts, an explicit upsert for projections. The private
    /// and device tiers keep the pre-epoch spelling — no writer there relies on the
    /// clause either (every one upserts explicitly or ignores), so it is inert.
    static let ddl = """
        CREATE TABLE IF NOT EXISTS "\(OrderRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
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
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL, "role" TEXT NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
          "address" TEXT NOT NULL,
          "building" TEXT,
          "entrance" TEXT, "floor" TEXT, "apartment" TEXT, "intercom" TEXT,
          "contactName" TEXT, "contactGivenName" TEXT, "contactFamilyName" TEXT,
          "contactPhone" TEXT, "contactPhoneExtension" TEXT,
          "visitStatus" TEXT, "visitedAt" REAL, "expectedVisitAt" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderItemRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL,
          "pickupStopRef" TEXT, "dropoffStopRef" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderCustomFieldRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "fieldRef" TEXT NOT NULL, "name" TEXT NOT NULL, "value" TEXT NOT NULL,
          "carrier" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderEventRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "legRef" TEXT,
          "providerEventID" INTEGER, "providerRevision" INTEGER,
          "at" REAL NOT NULL,
          "kind" TEXT NOT NULL, "providerStatus" TEXT,
          "detail" TEXT, "source" TEXT NOT NULL,
          "routeDigest" TEXT,
          "authorRef" TEXT, "signingKeyID" TEXT, "signature" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderMessageRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "sentAt" REAL NOT NULL, "kind" TEXT NOT NULL,
          "text" TEXT, "attachmentRef" TEXT, "authorHint" TEXT,
          "authorRef" TEXT, "signingKeyID" TEXT, "signature" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderAttachmentRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "kind" TEXT NOT NULL, "caption" TEXT, "byteSize" INTEGER,
          "createdAt" REAL NOT NULL, "authorHint" TEXT,
          "dataHash" TEXT,
          "authorRef" TEXT, "signingKeyID" TEXT, "signature" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(AttachmentBlobRow.tableName)" (
          "attachmentID" TEXT PRIMARY KEY NOT NULL
            REFERENCES "\(OrderAttachmentRow.tableName)"("id") ON DELETE CASCADE,
          "data" BLOB NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(ParticipantKeyRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "partyRef" TEXT,
          "keyID" TEXT NOT NULL, "publicKey" TEXT NOT NULL,
          "bindingKind" TEXT NOT NULL, "bindingProof" TEXT, "bindingKeyID" TEXT,
          "boundAt" REAL, "addedAt" REAL NOT NULL,
          "signature" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(MembershipRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "partyRef" TEXT NOT NULL, "role" TEXT NOT NULL,
          "addedAt" REAL NOT NULL,
          "authorRef" TEXT, "signingKeyID" TEXT, "signature" TEXT
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(OrderRatingRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "orderID" TEXT NOT NULL
            REFERENCES "\(OrderRow.tableName)"("id") ON DELETE CASCADE,
          "legRef" TEXT, "authorRef" TEXT,
          "subjectKind" TEXT NOT NULL, "subjectRef" TEXT NOT NULL,
          "subjectLabel" TEXT,
          "score" INTEGER NOT NULL, "comment" TEXT,
          "at" REAL NOT NULL,
          "signingKeyID" TEXT, "signature" TEXT
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
          "lastSeenActivityAt" REAL, "archivedAt" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(SavedPlaceRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "kind" TEXT NOT NULL,
          "pinned" INTEGER NOT NULL,
          "latitude" REAL NOT NULL, "longitude" REAL NOT NULL,
          "address" TEXT NOT NULL,
          "building" TEXT,
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
        CREATE TABLE IF NOT EXISTS "\(ParcelTemplateRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL, "pinned" INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(ParcelTemplateItemRow.tableName)" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "templateID" TEXT NOT NULL
            REFERENCES "\(ParcelTemplateRow.tableName)"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL,
          "name" TEXT NOT NULL, "quantity" INTEGER NOT NULL,
          "weightKg" REAL, "cost" TEXT, "currency" TEXT NOT NULL,
          "sizeLengthCm" REAL, "sizeWidthCm" REAL, "sizeHeightCm" REAL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS "\(LocalIdentityRow.tableName)" (
          "authority" TEXT PRIMARY KEY NOT NULL,
          "subject" TEXT NOT NULL, "partyRef" TEXT NOT NULL,
          "fetchedAt" REAL NOT NULL
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
          "building" TEXT,
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

    /// Columns added after a schema's birth — `CREATE TABLE IF NOT EXISTS` creates
    /// today's shape but never alters yesterday's table, so a late column gets an
    /// idempotent `ADD COLUMN` checked against `table_info` (SQLite can't add a
    /// column to a STRICT table conditionally; the pragma check is the guard).
    /// (table, column, type, backfill) quadruples, applied in order — `backfill`
    /// runs once, only when the column was just added.
    ///
    /// Empty at the epoch: `ydelivery-2.sqlite` is born with the whole shape above,
    /// and a store from before the epoch is *imported* (``EpochImport``), never
    /// altered in place. The mechanism stays for the columns that will arrive after
    /// this file's birth.
    static let columnMigrations: [(table: String, column: String, type: String,
                                  backfill: String?)] = []
}

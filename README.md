# YDeliveryKit

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/YDeliveryKit)

The foundation shared by [YDelivery](https://github.com/laconicman/YDelivery) and its
future extension targets (widgets, Live Activity) — extracted so any of them, and any
sibling app, consumes it **by version**, never by copy.

What lives here, and the membership test for anything added: *code an extension target
needs, which cannot import the app.*

- **Design system:** semantic colors (`Colors.xcassets` — status, point, place, scan,
  and the `feedback*` roles), `StatusChip`, `Notice`, `PointBadge`, `RouteLine`,
  `ETALabel`, `OrderIdentity`, the `Layout` and `SurfaceSize` tokens. `StatusChip`
  doubles as a control via its `disclosure` variant — a chevron inside the capsule
  tells a chip that expands something apart from one that only reports. `Notice`
  takes a caller-built `Text` so an app-owned key resolves in the app's catalog.
- **App models:** `Order`, `OrderStatus`, `RoutePoint`, `SavedPlace`, `AddressParts`,
  and `DeliveryActivityAttributes` — the Live Activity's shared schema, defined here
  because ActivityKit matches attributes by name *and module*: the app starts and
  updates the activity, the widget extension renders it, and two copies would be
  two activities. That is the package's one ActivityKit dependency, and it is why
  every consumer links the framework.
- **Persistence substrate:** `AppDatabase` — one `ydelivery-2.sqlite` in the App Group
  (SQLiteData + GRDB), the contract's three sync tiers, the epoch import of a
  pre-epoch `ydelivery.sqlite` beside it, legacy-JSON migration, and the lazy
  `SyncEngine` an extension target shares with the app. Both identifiers are the
  consuming app's to name (`inAppGroup(id:providerAccountRef:containerIdentifier:)`):
  the group, the provider account, and the CloudKit container belong to the host.
  The private tier holds the owner's view — notes, pins, and `archivedAt`, the
  shelf for a finished order — and never rides a share.

Swift 6, iOS 17 floor. Two targets, two dialects: `YDeliveryData` (models + persistence)
is `.defaultIsolation(nil)` — library code does not pick an executor for its callers;
`YDeliveryKit` (views, colors, tokens) keeps `MainActor` default, where `nonisolated`
remains explicit on pure value types. `import YDeliveryKit` re-exports the data half,
so consumers see one surface.
Swift Testing throughout. Depends on SFSafeSymbols, SQLiteData, GRDB, and
swift-structured-queries (the `StructuredQueriesSQLite` product is linked directly:
the `@Table` expansions resolve `StructuredQueriesCore` symbols against it).

Versioning: semantic, tags consumed by URL. Source-breaking changes bump the minor
while `0.x`, per the house rule in the consuming apps.

Why the components are shaped this way — the pin taxonomy, the semantic-color rules,
the motion table — is recorded in the consuming app's DocC catalogue
(`YDelivery/Documentation.docc/`), deliberately not re-derived here.

Schema epoch 2 (the app's `Schema` → "Epoch 2", 0.5.0): the store is reorganised the
way it should be rather than the way it happened — a new file (`ydelivery-2.sqlite`,
meant for a new CloudKit container the consumer names), no `ON CONFLICT REPLACE` on
any shared primary key, the history feed as `orderEvents` (every writer's, with the
columns the trust layer signs: `legRef`, `providerRevision`, `routeDigest`,
`authorRef`, `signingKeyID`, `signature`), the same signing triple on messages and
attachments (plus `dataHash`), and three new shared tables — `participantKeys`,
`memberships`, `orderRatings` — that exist before the first synced row. The signing
columns are written NULL by this version's writers; the trust layer fills them. A
pre-epoch store found beside the new file is imported once, row for row, on the
first open, then marked `*.imported-<t>-<id>` in place with its journals and its
hidden sqlite-data metadatabase. A copy that fails keeps the store unavailable for that
launch rather than open and empty; the old file waits for the next open.

The trust layer's primitives (0.5.1; the app's `Collaboration` → "Sign facts, derive
state"): `Signatory`, one device key in one of two custodies — the Secure Enclave where
there is one, a software P-256 key elsewhere — signing ECDSA P-256/SHA-256 as 64 raw bytes,
publishing the X9.63 point, named `p256.v2.<16 hex>`; `CanonicalPayload`, the `YDX2` byte
stream a signature covers, built from the same `DatabaseValue`s the writer binds and the
reader reads back, with the frozen v2 column lists and the sender-authored route digest;
`SigningKeyStore` with `EphemeralKeyStore` (the default, in memory) and the App Group
store's Keychain custody, cached only on success; and the read side's vocabulary —
`Verdict`, `Attested`, `Party`, `ParticipantKey`, `IdentityAuthority` — with no
implementation yet. The Keychain item lives here and not in the app by the membership
test: the extension targets write too (a photo posted from the share extension must sign
with the same device key), and the key is resolved once per process, outside any write
transaction, so a slow Keychain never holds the SQLite lock across a suspension. Nothing
signs in 0.5.1: the writers and the verdicts land as their own patches.

Key rows and memberships (0.5.2; the app's `Schema` → "Stage 1", `Collaboration` →
"Keys"): a device publishes its key into an order as a self-signed `participantKeys` row
under `orderID ‖ keyID ‖ bindingKind`, inside the first signed write; `memberships` mirrors
the share — a signed `participant` row per accepted participant under
`orderID ‖ partyRef ‖ keyID ‖ generation`, a `removed` row when the share no longer lists a
party, a caller-held row per role assignment — and the row in force is selected at read
(latest `addedAt`; on a tie `removed` dominates, then the smallest id), as of the row being
judged. `CloudKitIdentityAuthority` is the one place CloudKit vocabulary reaches the trust
layer: it resolves a key row's creator stamp to a party and lists an order's members from
the cached share merged with the rows. `Entitlement.mayWrite` is the matrix.

Signed facts and the verdicts (0.5.3): `recordEvent`, `postMessage` and `postPhotoMessage`
sign exactly the values they bind, in the same statement, with the device's key published
into the order in the same transaction; a derived event id is re-derived under the
writer's key, so two devices recording one fact write two rows. The attested reads —
`attestedEvents`, `attestedMessages`, `attestedAttachment` — hand back `Attested` values
with a verdict each, computed from the stored row and the key row its `signingKeyID`
names, the key's binding resolved through the authority, entitlement judged as of the
row's stamp; events are deduped by fact at read. `mirrorIntegrity` and `routeIntegrity`
check the projections against the latest verified fact under one total order, and the
mirror itself follows that order at an equal stamp, so the two agree. A revisionless
sighting keys on its own stamp; a signed replay of a fact already recorded unsigned adds
no row. The share's list is the trigger and the owner's signed rows are the dates: the
reconcile mirrors the share's permission too — a `reader` row for a participant it lists
read-only, a new row per change under the next revision of the admission, a restored
permission bringing back the role the rows last gave — and the party
book places a party only when the list and the rows agree on their standing, the
effective row as of the stamp then naming the role; a disagreement (a departure, a
permission change, a return the owner's device has not mirrored) places nobody until it
is dated, and no cached share places nobody but the owner. A photo whose bytes are not
here yet reads unverifiable. The unattested reads stay for callers that render no verdict.

Ratings (0.5.4; the app's `Vision` → "Players, trust and reputation"): a rating is a
signed, append-only fact in `orderRatings`, not a message kind — the chat renders it as an
event row beside the messages. `postRating` refuses a score outside 1 to 5 and an order
that is not a row here, and signs like the chat writers: the values the statement binds,
the device's key published in the same transaction, the pair NULL when custody fails. The
id is the caller's and never derived — a rating is a decision, so two equal ratings are
two rows and a retry under one id is one. `attestedRatings` hands back every row with its
verdict, oldest first; `effectiveRatings` selects, per author and subject, the latest row
that reads verified or legacy (on a tie the smallest id), keeps the rows it superseded as
that rating's history, and returns every other row beside them as not counted, never
dropped. `ratingSummary` is the count and mean of one subject's counted ratings across
the store's orders, one per author per order: the sender's own experience, derived at
read and never persisted — not a reputation, since other senders' ratings live in shares
this device is not in.

Adoption seams (0.5.5; the app's `Collaboration` → "Sign facts, derive state", rule 1):
`postPhotoMessage` takes an `authorRef`, stamped on the attachment, its message and the
key row the post may publish, so a photo names its author the way `postMessage` already
did; the default is `nil`, today's post. `CloudKitIdentityAuthority.noteLocalParty()` asks
the container for its user record and notes it as the device's party, returning the
`partyRef`: the party derived under the provider word `cloudkit`, the `localIdentity` row
keyed by `cloudkit:<container>` — the two strings composed in one place, and the record
name never leaving the authority.

One consumer-facing honesty note: the substrate never destroys bytes. A malformed
legacy file is rescued aside as `*.corrupted-<t>-<id>.json` before the store opens;
a failed open is a stored error to render, never a crash and never silent-empty.
Synced tables obey one write discipline for the same reason: upsert and prune,
never delete-then-reinsert or `INSERT OR REPLACE` — sqlite-data's metadata would
tombstone the re-created row or never re-queue it, and the edit would never reach
CloudKit (YD-34 in the app's register). A cleared value is a kept empty row, not
a delete — the tombstone is deleted only when the server acknowledges it, so a
re-created key before that round-trip would inherit `_isDeleted` and stay dead.

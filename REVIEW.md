# Review Guidelines

Review-specific guidance for this package. `README.md` states what belongs here (the
membership test: code an extension target needs, which cannot import the app); these are
the diff-level cues and the noise filters.

## Critical Areas

- Flag any hardcoded App Group, bundle identifier, or other single-app identity. The
  stores take the group by parameter (`inAppGroup(id:)`) — this package serves any
  consumer, and a baked-in identifier silently binds it to one (the extraction's one
  API change existed to remove exactly this).
- Flag a change to the JSON substrate that can destroy bytes: reads must keep treating
  absence and malformed content as empty without touching the file, and writes must keep
  rescuing unreadable bytes aside before overwriting (`OrderStore.record`'s documented
  contract).
- Flag a public API removal or rename that is not paired with a version-note in the PR
  description — consumers pin tags (`minorVersion` while 0.x), so source breaks are
  minor bumps, stated, never slipped.
- Flag an import of anything beyond Foundation / SwiftUI / SFSafeSymbols — and, in
  `YDeliveryData`, CryptoKit (the attachment hash, the P-256 signatures and digests) and
  Security (the device key's Keychain item), each confined to the files that need it. A
  new dependency here taxes every consumer and needs the README's membership argument
  made explicitly.
- Flag a signature computed over anything but the values the same statement binds — a
  `SELECT` feeding a signature, a stored row re-read to re-sign it, a rotation or
  "ensure" pass — and a signature pair written stale rather than NULL when custody
  fails (the app's `Collaboration` → rule 3).
- Flag a verdict stored in a column or reaching Codable output: verdicts are read-time
  values beside the model (`Attested`), never fields on it (rule 5).
- Flag a CloudKit type above the identity authority adapter, a Keychain item with
  `kSecAttrSynchronizable` true or without an explicit accessibility, and a key store
  that caches a failure: only a resolved key is cached (rules 4 and 8). The adapter is
  `CloudKitIdentityAuthority.swift`; with `Sharing.swift` it is the only file in
  `YDeliveryData` that imports CloudKit.
- Flag a role or a name column on `participantKeys`: roles come from `memberships` and
  `legs`, never from a writer's claim, and names from the authority at render time.
- Flag a membership `UPDATE` or `DELETE`, or a role assignment under a derived id: a
  role change is a new row under a caller-held id, a removal a `removed` row, and the
  row in force is selected at read (`Membership.effective`).
- Flag a `SyncMetadata` read inside a write transaction, or one that does not go through
  `withMetadatabase`: the metadatabase attaches when the engine is constructed, and a
  Keychain or metadata read must never hold the SQLite write lock.
- Flag a fact writer (`orderEvents`, `orderMessages`, `orderAttachments`, `orderRatings`)
  that bypasses `insertSigned`, a `SELECT` that feeds a signature, a signature pair
  written stale rather than NULL on a custody failure, and an attested read that throws
  on a bad signature or drops a row: verdicts render beside the data, never refuse it.
- Flag a projection update that settles an equal-stamp tie by arrival rather than
  `AppDatabase.precedes` over status-bearing rows, and a role resolution that places a
  party from the share's list alone or from membership rows alone: the mirror and
  `mirrorIntegrity` share one total order, and a party is placed only when the list
  and the owner's rows agree on their standing — an undated departure or permission
  change places nobody until the reconcile dates it (review, PR #48).
- Flag `ON CONFLICT REPLACE` on any shared-tier primary key, and a bare `INSERT` on a
  fact table (`orderEvents`, `orderMessages`, `orderAttachments`, `participantKeys`,
  `memberships`, `orderRatings`) that does not state its policy — `INSERT OR IGNORE`
  for a fact, an explicit upsert for a projection (the app's `Schema` → "Primary
  keys"). A column's REPLACE clause rewrites a row invisibly to sync and, once rows
  are signed, replaces a signed row wholesale.
- Flag a write that *updates* a fact table's row, or re-derives a fact's id without
  its revision and route digest: facts are append-only and their identity is the
  fact's (`Schema` → "Identity on signed tables").
- Flag a change to `EpochImport` that deletes, overwrites or rewrites the pre-epoch
  store: it is copied read-only and marked aside, never destroyed; a copy failure
  leaves it in place for the next open.

## Conventions

- Require a running `#Preview` on every view in the diff (`StatusChip`, `PointBadge`,
  and successors); previews construct their own values and never require a consumer's
  environment.
- Pure value types and their extensions in `Sources/YDeliveryKit/` are `nonisolated` —
  extensions do **not** inherit it from the type under that target's MainActor-default
  isolation, so flag a new extension on a UI-adjacent value type that omits the keyword
  (the app repo paid for this twice). The inverse holds in `Sources/YDeliveryData/`:
  flag `nonisolated` there as a no-op — the target's whole module is nonisolated by
  explicit `.defaultIsolation(nil)`.
- Status semantics never ride on color alone: a status-bearing component pairs its
  color with a glyph and words, and the grayscale-distinguishability test is the
  regression gate — flag a new status surface without one.
- Swift Testing throughout (`#expect`/`#require`, suites per component); store tests
  write into temporary directories, never a real container.
- Shared measures come from the `Layout` tokens; flag new magic numbers where a token
  or a named constant beside the component belongs.
- Open string vocabularies are deliberate: `OrderRating.Subject.Kind`, like
  `OrderMessage.Kind`, `OrderEvent.Kind`, `Membership.Role` and
  `ParticipantKey.BindingKind`, is a namespace of named constants over a stored string,
  so a newer peer's word decodes instead of failing — do not ask for a closed enum. Flag
  a bare literal where a named constant exists instead.

## Noise Filters

- Localized strings here resolve against the package's own bundles via the
  `LocalizedStringResource` helpers — `.kit` for the UI target, `.data` for the
  data target — do not flag the absence of `Bundle.main`-style lookups; their
  presence would be the defect.
- `Package.resolved` is committed deliberately (records the known-good SFSafeSymbols
  pin for the standalone test run); do not flag it as an accident.

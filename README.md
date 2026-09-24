# YDeliveryKit

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/YDeliveryKit)

The foundation shared by [YDelivery](https://github.com/laconicman/YDelivery) and its
future extension targets (widgets, Live Activity) — extracted so any of them, and any
sibling app, consumes it **by version**, never by copy.

What lives here, and the membership test for anything added: *code an extension target
needs, which cannot import the app.*

- **Design system:** semantic colors (`Colors.xcassets`), `StatusChip`, `PointBadge`,
  `RouteLine`,
  the `Layout` tokens.
- **App models:** `Order`, `OrderStatus`, `RoutePoint`, `SavedPlace`, `AddressParts`.
- **Persistence substrate:** `AppDatabase` — one `ydelivery.sqlite` in the App Group
  (SQLiteData + GRDB), the contract's three sync tiers, legacy-JSON migration, and the
  lazy `SyncEngine` an extension target shares with the app. Both identifiers are the
  consuming app's to name (`inAppGroup(id:providerAccountRef:containerIdentifier:)`):
  the group, the provider account, and the CloudKit container belong to the host.

Swift 6, iOS 17 floor, `MainActor` default isolation with `nonisolated` value types.
Swift Testing throughout. Depends on SFSafeSymbols, SQLiteData, GRDB, and
swift-structured-queries (the `StructuredQueriesSQLite` product is linked directly:
the `@Table` expansions resolve `StructuredQueriesCore` symbols against it).

Versioning: semantic, tags consumed by URL. Source-breaking changes bump the minor
while `0.x`, per the house rule in the consuming apps.

Why the components are shaped this way — the pin taxonomy, the semantic-color rules,
the motion table — is recorded in the consuming app's DocC catalogue
(`YDelivery/Documentation.docc/`), deliberately not re-derived here.

One consumer-facing honesty note: the substrate never destroys bytes. A malformed
legacy file is rescued aside as `*.corrupted-<t>-<id>.json` before the store opens;
a failed open is a stored error to render, never a crash and never silent-empty.

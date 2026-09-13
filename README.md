# YDeliveryKit

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/YDeliveryKit)

The foundation shared by [YDelivery](https://github.com/laconicman/YDelivery) and its
future extension targets (widgets, Live Activity) — extracted so any of them, and any
sibling app, consumes it **by version**, never by copy.

What lives here, and the membership test for anything added: *code an extension target
needs, which cannot import the app.*

- **Design system:** semantic colors (`Colors.xcassets`), `StatusChip`, `PointBadge`,
  the `Layout` tokens.
- **App models:** `Order`, `OrderStatus`, `RoutePoint`, `SavedPlace`, `AddressParts`.
- **Local stores:** `OrderStore`, `SavedPlaceStore` — one JSON substrate for history,
  recents, saved places and repeat-order. Both take the App Group **by parameter**
  (`inAppGroup(id:)`): the group is the consuming app's to name, this package serves
  any of them.

Swift 6, iOS 17 floor, `MainActor` default isolation with `nonisolated` value types.
Swift Testing throughout. Depends on SFSafeSymbols only.

Versioning: semantic, tags consumed by URL. Source-breaking changes bump the minor
while `0.x`, per the house rule in the consuming apps.

Why the components are shaped this way — the pin taxonomy, the semantic-color rules,
the motion table — is recorded in the consuming app's DocC catalogue
(`YDelivery/Documentation.docc/`), deliberately not re-derived here.

One consumer-facing honesty note: a malformed store file reads as empty, and its bytes
are rescued aside as `*.corrupted-<t>-<id>.json` on the next write. There is no API yet
for discovering those sidecars — a consumer that wants to surface corruption should
look for them beside the store files; an API earns its way in with the first consumer
that needs one.

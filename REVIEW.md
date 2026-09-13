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
- Flag an import of anything beyond Foundation / SwiftUI / SFSafeSymbols. A new
  dependency here taxes every consumer and needs the README's membership argument made
  explicitly.

## Conventions

- Require a running `#Preview` on every view in the diff (`StatusChip`, `PointBadge`,
  and successors); previews construct their own values and never require a consumer's
  environment.
- Pure value types and their extensions are `nonisolated` — extensions do **not**
  inherit it from the type under MainActor-default isolation, so flag a new extension
  on a model type that omits the keyword (the app repo paid for this twice).
- Status semantics never ride on color alone: a status-bearing component pairs its
  color with a glyph and words, and the grayscale-distinguishability test is the
  regression gate — flag a new status surface without one.
- Swift Testing throughout (`#expect`/`#require`, suites per component); store tests
  write into temporary directories, never a real container.
- Shared measures come from the `Layout` tokens; flag new magic numbers where a token
  or a named constant beside the component belongs.

## Noise Filters

- Localized strings here resolve against the package bundle via the
  `LocalizedStringResource` kit-bundle helper — do not flag the absence of
  `Bundle.main`-style lookups; their presence would be the defect.
- `Package.resolved` is committed deliberately (records the known-good SFSafeSymbols
  pin for the standalone test run); do not flag it as an accident.

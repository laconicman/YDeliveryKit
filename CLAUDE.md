# YDeliveryKit — shared foundation package

The design system, app models, and local stores under
[YDelivery](https://github.com/laconicman/YDelivery) and its future extension targets.
`README.md` states what belongs here (the membership test) and how the stores behave;
`REVIEW.md` carries the diff-level review cues. Design *rationale* lives in the consuming
app's DocC catalogue — cite it, do not re-derive it.

## Rules specific to this repository

1. **Everything lands via PR** (author, 2026-09-13). `main` is protected; Devin Review
   runs on push and `REVIEW.md` steers it. No AI attribution in commit messages or PR
   descriptions. Direct pushes ended with `0.1.1`.
2. **The App Group is the consumer's to name.** `inAppGroup(id:)` takes it by parameter;
   a hardcoded group or bundle identifier binds the package to one app and is a defect.
3. **The substrate never destroys bytes.** Absent and malformed files read as empty;
   unreadable files throw; writes rescue undecodable bytes into collision-proof
   `*.corrupted-<t>-<id>.json` sidecars before overwriting.
4. **Isolation differs per target.** `YDeliveryKit` (the UI half) runs MainActor
   default: pure value types and their extensions there are `nonisolated` — extensions
   do not inherit it, so state it every time. `YDeliveryData` (models + persistence)
   is explicitly `.defaultIsolation(nil)`: `nonisolated` is a no-op there — do not
   write it. New files choose their target by kind: views, colors, layout tokens →
   `YDeliveryKit`; value types, stores, sync machinery → `YDeliveryData`. The one
   exception is `DeliveryActivityAttributes`: ActivityKit keys a type by name *and*
   module, so it stays UI-side to keep in-flight Live Activities matching across
   updates — its own doc comment says so.
5. **Additive changes patch; source breaks bump the minor while `0.x`, stated in the PR
   description.** Consumers pin `minorVersion`, so an unstated break lands on them at
   their next resolve.
6. **Swift Testing; every view carries a running `#Preview`.** The platform floor is
   iOS 17 and the package is iOS-only — test against a simulator destination:
   `xcodebuild test -scheme YDeliveryKit -destination 'platform=iOS Simulator,name=<device>'`
   (`swift test` on macOS will not build it).

## Release flow

Green tests → tag (`git tag <version> && git push origin main <version>`) → consumers
pick up patches automatically via `minorVersion`; announce minor bumps in the consuming
repo's PR that adopts them.

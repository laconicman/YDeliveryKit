import SwiftUI

/// The arrival estimate, spoken the same way on every surface (board `5e`):
/// «в 9:41» on the clock form, «~14 мин» on the duration form, and «обычно
/// 3–7 мин» when the provider has no estimate to give — the typical window is
/// the honest answer to "when", not an empty slot.
///
/// Renders from plain values only (the package's membership test): the caller
/// supplies the arrival moment — `Order.etaAt` — and the confidence the wire
/// earned. Yandex's `eta` is minutes-to-completion, always an estimate; the
/// `confirmed` case waits for a firmer wire field rather than fake precision.
/// Deliberately a fixed reading, never a ticking timer (board `5a`): a
/// countdown implies a precision the estimate does not have.
public struct ETALabel: View {
    /// How firm the moment is. `.estimate` marks the duration form with «~»;
    /// the clock form is already "the estimate's hour" and takes no extra mark.
    public nonisolated enum Confidence: Sendable, Hashable {
        case estimate
        case confirmed
    }

    /// Which reading the surface needs. `.clock` is the headline («в 9:41» —
    /// a time the sender can plan against); `.duration` is the supporting
    /// answer («~14 мин» — how long the wait feels). The board puts both on
    /// the Lock Screen; they are two instances of this label, not a mode.
    public nonisolated enum Presentation: Sendable, Hashable {
        case clock
        case duration
    }

    let at: Date?
    let observedAt: Date?
    let confidence: Confidence
    let presentation: Presentation

    /// `at` is the arrival moment (`Order.etaAt`); `observedAt` is the
    /// provider's as-of stamp. The `.duration` form reads `at − observedAt` —
    /// the vendor's own estimate, rendered once — because a timeline style
    /// (`.relative`) would keep recounting as the clock ticks, turning one
    /// observation into a fake countdown (review, Kit PR #8). Without a stamp
    /// it freezes `at − now` at render; either way the text itself never moves.
    public init(
        at: Date?,
        observedAt: Date? = nil,
        confidence: Confidence = .estimate,
        presentation: Presentation = .clock
    ) {
        self.at = at
        self.observedAt = observedAt
        self.confidence = confidence
        self.presentation = presentation
    }

    /// The wait as a fixed figure — the estimate's own minutes, floored at
    /// zero: a lapsed ETA is a stale sighting, not a debt of negative time.
    /// A plain string because the label must never tick (see `init`).
    nonisolated static func durationString(at: Date, observedAt: Date?) -> String {
        let interval = max(0, at.timeIntervalSince(observedAt ?? .now))
        let minutes = (interval / 60).rounded()
        return Measurement(value: minutes, unit: UnitDuration.minutes)
            .formatted(.measurement(width: .abbreviated))
    }

    public var body: some View {
        guard let at else {
            // The fixed typical window — content, not a magic string: «обычно
            // 3–7 мин» is what the service answers when it has no estimate.
            return Text(LocalizedStringResource("usually 3–7 min", bundle: .kit))
        }
        return switch presentation {
        case .clock:
            Text(LocalizedStringResource("by", bundle: .kit))
                + Text(" ")
                + Text(at, style: .time)
        case .duration:
            switch confidence {
            case .estimate: Text("~") + Text(Self.durationString(at: at, observedAt: observedAt))
            case .confirmed: Text(Self.durationString(at: at, observedAt: observedAt))
            }
        }
    }
}

#Preview("Three readings of one wait") {
    let observed = Date.now
    VStack(alignment: .leading, spacing: Layout.Spacing.unit) {
        ETALabel(at: observed.addingTimeInterval(14 * 60),
                 observedAt: observed, presentation: .clock)
        ETALabel(at: observed.addingTimeInterval(14 * 60),
                 observedAt: observed, presentation: .duration)
        ETALabel(at: nil, presentation: .duration)
    }
    .padding()
}

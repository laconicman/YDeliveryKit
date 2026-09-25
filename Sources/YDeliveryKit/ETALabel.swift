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
    let confidence: Confidence
    let presentation: Presentation

    public init(
        at: Date?,
        confidence: Confidence = .estimate,
        presentation: Presentation = .clock
    ) {
        self.at = at
        self.confidence = confidence
        self.presentation = presentation
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
            // `.relative` renders the wait in the locale's own words —
            // «через 14 мин» / "in 14 min" — so the only thing to mark is the
            // estimate's tilde.
            switch confidence {
            case .estimate: Text("~") + Text(at, style: .relative)
            case .confirmed: Text(at, style: .relative)
            }
        }
    }
}

#Preview("Three readings of one wait") {
    let eta = Date.now.addingTimeInterval(14 * 60)
    VStack(alignment: .leading, spacing: 8) {
        ETALabel(at: eta, presentation: .clock)
        ETALabel(at: eta, presentation: .duration)
        ETALabel(at: nil, presentation: .duration)
    }
    .padding()
}

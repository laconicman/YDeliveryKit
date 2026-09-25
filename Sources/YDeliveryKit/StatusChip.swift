import SFSafeSymbols
import SwiftUI

/// The one rendering of an order's status: color, glyph, and words, always together —
/// a status color never appears without its glyph and its words (DesignSystem →
/// "Semantic colors"), so removing color costs nothing.
///
/// A `ViewThatFits` candidate list (decision #31), authored most complete first;
/// the last candidate is the irreducible minimum, which still carries glyph and words —
/// type and padding shrink first, and past that the words wrap. Nothing truncates.
public struct StatusChip: View {
    let status: OrderStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: OrderStatus) {
        self.status = status
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            label(font: .footnote, padding: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            // Doubles as the overflow strategy: when even this candidate cannot fit —
            // long translations, accessibility sizes, a narrow widget — ViewThatFits
            // still renders it, width-constrained, and the unlimited line count lets
            // the words wrap. The chip grows down rather than dropping its words.
            label(font: .caption2, padding: EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
        }
    }

    private func label(font: Font, padding: EdgeInsets) -> some View {
        Label {
            Text(status.words)
        } icon: {
            if let symbol = status.symbol {
                Image(systemSymbol: symbol)
                    // The searching glyph is the spinner: the one genuinely indeterminate
                    // wait (DesignSystem → "Motion"). Reduce Motion: static glyph + words.
                    .symbolEffect(
                        .variableColor,
                        isActive: status == .searching && !reduceMotion
                    )
            }
        }
        // Cancelled recedes at regular weight: its AA-darkened value must not read as
        // prominence — recession comes from the neutral tint and the weight, and the
        // ✕ plus the word are what separate it from draft (designer, 2026-08-30).
        .font(font.weight(status == .cancelled ? .regular : .medium))
        .foregroundStyle(foreground)
        .padding(padding)
        .background(background, in: Capsule())
    }

    /// Draft is the one status whose token is a *fill*, not a text color — «Черновик» has
    /// no color of its own to speak in, so the words render as secondary text on the
    /// neutral capsule. Every other status speaks in its color, on a whisper of itself.
    private var foreground: AnyShapeStyle {
        status == .draft ? AnyShapeStyle(.secondary) : AnyShapeStyle(status.color)
    }

    private var background: AnyShapeStyle {
        status == .draft ? AnyShapeStyle(status.color) : AnyShapeStyle(status.color.opacity(0.12))
    }
}

extension OrderStatus {
    /// The semantic token behind this status (DesignSystem color table). Compile-time
    /// symbols from the package's catalog: a typo is a build error, not a blank widget.
    /// Public: the set lives in the shared package precisely so every consumer speaks
    /// the same green — the chip is the usual voice, this is the raw token.
    public var color: Color {
        switch self {
        case .draft: Color(.statusDraft)
        case .searching: Color(.statusSearching)
        case .active: Color(.statusActive)
        case .done: Color(.statusDone)
        case .attention: Color(.statusAttention)
        case .cancelled: Color(.statusCancelled)
        }
    }

    /// The paired glyph — `nil` only for draft, whose table row is "— · «Черновик»".
    /// Public for surfaces that draw the glyph without the capsule (a Live
    /// Activity's island icon, a lock-screen accessory).
    public var symbol: SFSymbol? {
        switch self {
        case .draft: nil
        case .searching: .circleDotted
        case .active: .recordCircle
        case .done: .checkmark
        case .attention: .exclamationmarkTriangleFill
        case .cancelled: .xmark
        }
    }

    /// The paired words. Localized in the package bundle so every consumer — app, widget,
    /// notification — says exactly the same thing.
    public var words: LocalizedStringResource {
        switch self {
        case .draft: LocalizedStringResource("Draft", bundle: .kit)
        case .searching: LocalizedStringResource("Finding a courier", bundle: .kit)
        case .active: LocalizedStringResource("Courier on the way", bundle: .kit)
        case .done: LocalizedStringResource("Delivered", bundle: .kit)
        case .attention: LocalizedStringResource("Not delivered", bundle: .kit)
        case .cancelled: LocalizedStringResource("Cancelled", bundle: .kit)
        }
    }
}

#Preview("All statuses") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(OrderStatus.allCases, id: \.self) { status in
            StatusChip(status: status)
        }
    }
    .padding()
}

#Preview("Tight fit falls back, never drops words") {
    StatusChip(status: .searching)
        .frame(width: 96)
        .padding()
}

#Preview("Overflow wraps, never truncates") {
    StatusChip(status: .active)
        .frame(width: 64)
        .padding()
}

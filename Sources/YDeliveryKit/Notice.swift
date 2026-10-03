import SFSafeSymbols
import SwiftUI

/// The canonical feedback row — glyph and words speaking one role's vocabulary
/// (DesignSystemSemantics → "The proposed vocabulary"). `bound` is a precondition
/// stated where it's decided, never an error; `warning` is proceedable-but-risky or
/// an answer that came back unknown; `error` is something tried that failed;
/// `info` is guidance that asks for no hue at all.
///
/// The two-entries rule is built in: the glyph keeps the role's bright hue
/// (non-text graphics clear at 3:1) while the words take the darkened text token —
/// system `.red`/`.orange` fail 4.5:1 at footnote size. Color is still never the
/// only channel: the glyph and the words both carry the meaning.
///
/// This is the *row*, not the failure block — Retry/Check again/Share diagnostics
/// belong to the surface, laid out beside or below the notice as the site needs
/// (a failed read stays quiet `.secondary` text and doesn't reach for this view).
/// No font is applied; the site picks footnote/subheadline/caption to fit its seat.
public struct Notice: View {
    /// The four feedback roles that have chrome. (Read-failures are deliberately
    /// absent — a failed read is a retry, not an error, and renders `.secondary`.)
    public enum Role {
        /// Guidance, provenance, invitations — `.secondary`, glyph only where a
        /// scanning eye needs one.
        case info
        /// A precondition, visible before it is broken. Attention's hue family on
        /// purpose: a bound is a decision the sender owes, not a failure.
        case bound
        /// Proceedable-but-risky, or an outcome that came back uncertain.
        case warning
        /// An action tried and failed — a write, a command, a refusal.
        case error
    }

    let role: Role
    let message: Text
    let symbol: SFSymbol?

    /// A literal (localized) message. `symbol` overrides the role's default glyph —
    /// a cause that has its own mark uses it (`.wifiSlash` for a dead connection).
    public init(_ role: Role, _ message: LocalizedStringKey, symbol: SFSymbol? = nil) {
        self.init(role, Text(message), symbol: symbol)
    }

    /// A runtime string, rendered verbatim — a provider's `errorDescription` lands
    /// here, never re-keyed through localization.
    public init(_ role: Role, _ message: some StringProtocol, symbol: SFSymbol? = nil) {
        self.init(role, Text(message), symbol: symbol)
    }

    private init(_ role: Role, _ message: Text, symbol: SFSymbol?) {
        self.role = role
        self.message = message
        self.symbol = symbol ?? role.defaultSymbol
    }

    public var body: some View {
        if let symbol {
            Label {
                message.foregroundStyle(role.textStyle)
            } icon: {
                Image(systemSymbol: symbol)
                    .foregroundStyle(role.glyphStyle)
            }
        } else {
            message.foregroundStyle(role.textStyle)
        }
    }
}

nonisolated extension Notice.Role {
    /// The role's glyph — `nil` for `info`, whose rows stand on words alone unless
    /// the site overrides (a list of hints scans better with a mark).
    var defaultSymbol: SFSymbol? {
        switch self {
        case .info: nil
        case .bound: .exclamationmarkCircle
        case .warning, .error: .exclamationmarkTriangle
        }
    }

    /// The glyph's hue — bright system colors are fine for a graphic (the non-text
    /// bar is 3:1); only `bound` draws from the catalog since its hue *is* the role.
    var glyphStyle: AnyShapeStyle {
        switch self {
        case .info: AnyShapeStyle(.secondary)
        case .bound: AnyShapeStyle(Color(.kitFeedbackBound))
        case .warning: AnyShapeStyle(.orange)
        case .error: AnyShapeStyle(.red)
        }
    }

    /// The words' style — the AA-darkened text tokens where a hue speaks at all.
    var textStyle: AnyShapeStyle {
        switch self {
        case .info: AnyShapeStyle(.secondary)
        case .bound: AnyShapeStyle(Color(.kitFeedbackBound))
        case .warning: AnyShapeStyle(Color(.kitFeedbackWarningText))
        case .error: AnyShapeStyle(Color(.kitFeedbackErrorText))
        }
    }
}

#Preview("One row per role") {
    VStack(alignment: .leading, spacing: 12) {
        Notice(.info, "Places are saved from a stop while composing.")
        Notice(.bound, "Required — the order doesn't leave without it.")
        Notice(.warning, "This pin was guessed from the text — check the map.")
        Notice(.error, "The provider refused the save.")
    }
    .font(.footnote)
    .padding()
}

#Preview("A cause with its own mark") {
    Notice(.error, "The connection dropped mid-send.", symbol: .wifiSlash)
        .font(.footnote)
        .padding()
}

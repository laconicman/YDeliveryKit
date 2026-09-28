import Foundation

/// The shared density axis for components that render outside the app (board
/// `5e` — "sizing, not styling"): a widget cannot grow to fit its content, so
/// the content takes the size instead. `compact` is the irreducible form —
/// glyph or bare words; `regular` is the app's default reading; `expanded`
/// adds the supporting detail a Lock Screen or StandBy layout can hold.
public nonisolated enum SurfaceSize: Sendable, Hashable {
    case compact, regular, expanded
}

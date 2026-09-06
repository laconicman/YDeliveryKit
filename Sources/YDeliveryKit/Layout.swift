import CoreGraphics

/// The shared layout vocabulary: spacing named by role on the 8-point grid, corner radii
/// named by surface, held heights named by what holds them. One home so no magic number
/// appears at a call site (author's standing preference, 2026-09-06) — a one-off measure
/// that genuinely belongs to a single component stays a *named* constant beside it.
public nonisolated enum Layout {
    /// Gaps, smallest to widest. Named by what they separate, not by their value.
    public enum Spacing {
        /// A title from its subtitle inside one row.
        public static let hairline: CGFloat = 2
        /// A glyph from its own label.
        public static let tight: CGFloat = 4
        /// A chip's innards.
        public static let chip: CGFloat = 6
        /// Siblings within a group — the grid unit.
        public static let unit: CGFloat = 8
        /// Cards in a strip.
        public static let cards: CGFloat = 10
        /// A row's leading gutter; a card's inner padding.
        public static let gutter: CGFloat = 12
        /// Content from the screen's edge.
        public static let edge: CGFloat = 16
    }

    /// Corner radii by surface.
    public enum Radius {
        /// Small inline fields.
        public static let field: CGFloat = 8
        /// Bars and compact floating containers.
        public static let bar: CGFloat = 10
        /// Cards.
        public static let card: CGFloat = 14
    }

    /// Heights a state change must not collapse (decision #13's general form).
    public enum MinHeight {
        /// A one-line information bar.
        public static let bar: CGFloat = 36
        /// The tariff strip, cards or not.
        public static let strip: CGFloat = 88
    }
}

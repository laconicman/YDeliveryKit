import SFSafeSymbols
import SwiftUI

/// The one rendering of a route point's role — the board `2c` shape/glyph pair. Shape and
/// glyph carry the role; color only reinforces (DesignSystem → "Pin & badge taxonomy"),
/// so every role survives grayscale. Map marker and list badge are this same view, which
/// is what makes the route list the map's legend. On a map, anchor the annotation at
/// ``Role/mapAnchor`` — the teardrop's tip is the coordinate.
///
/// A `ViewThatFits` candidate list (decision #31), authored most complete first:
/// the regular mark, then the compact mark as the irreducible minimum for tight rows.
/// The mark does not scale with type — at accessibility sizes the row grows and the glyph
/// keeps its size (board `3f`, the reflow ladder), which is why neither candidate reads
/// the environment's font.
public struct PointBadge: View {
    /// What the point *is* in the route — the rows of the `2c` table. Ends are symbols,
    /// not letters: A/B badges are withdrawn (they carry no meaning, need localizing at
    /// accessibility sizes, and collide with numbered stops).
    ///
    /// `nonisolated`, like `OrderStatus`: plain value vocabulary with no UI affinity.
    public nonisolated enum Role: Hashable, Sendable {
        /// Start · pickup — the concentric ring every map uses for the origin.
        case start
        /// Intermediate stop, numbered from the datum (the stop's position in the route,
        /// not an array index) so the badge survives reordering.
        case stop(number: Int)
        /// End · drop-off — the teardrop.
        case end
        /// Return point — where what could not be handed over goes back.
        case returnPoint
        /// A saved place kind: the sender's warehouse.
        case warehouse
        /// A saved place kind: staffed pick-up point (ПВЗ).
        case staffedPickup
        /// A saved place kind: parcel locker (постамат).
        case locker
    }

    let role: Role

    public init(role: Role) {
        self.role = role
    }

    /// The two candidates' sizes — the board's row mark, and the dense-row minimum.
    private static let regularDiameter: CGFloat = 22
    private static let compactDiameter: CGFloat = 14

    public var body: some View {
        ViewThatFits {
            mark(diameter: Self.regularDiameter)
            // The irreducible minimum: the same shape and glyph, compact — for dense
            // rows (history cards, widget lines). Never a letter, never color alone.
            mark(diameter: Self.compactDiameter)
        }
        .accessibilityLabel(Text(role.words))
    }

    @ViewBuilder
    private func mark(diameter: CGFloat) -> some View {
        switch role.shape {
        case .circle:
            Circle()
                .fill(role.color)
                .overlay { role.glyph(diameter: diameter) }
                .frame(width: diameter, height: diameter)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: diameter * 0.23)
                .fill(role.color)
                .overlay { role.glyph(diameter: diameter) }
                .frame(width: diameter, height: diameter)
        case .teardrop:
            // A circle with one square corner, rotated so the point hangs down — the
            // classic pin, drawn rather than shipped as an asset. The sharp corner
            // protrudes (√2 − 1)/2 of the diameter below the round body, which is where
            // the extra height of `teardropAspectRatio` goes; the glyph rides the body.
            UnevenRoundedRectangle(
                topLeadingRadius: diameter / 2,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: diameter / 2,
                topTrailingRadius: diameter / 2
            )
            .fill(role.color)
            .overlay { role.glyph(diameter: diameter) }
            .rotationEffect(.degrees(-45))
            .frame(width: diameter, height: diameter)
            .frame(
                width: diameter,
                height: diameter * Role.Shape.teardropAspectRatio,
                alignment: .top
            )
        }
    }
}

extension PointBadge.Role {
    /// The board's grayscale test, as a type: every role must stay distinguishable with
    /// color removed, so the (shape, glyph) pair — not the color — is what varies.
    nonisolated enum Shape: Hashable {
        case circle
        case teardrop
        case roundedSquare

        /// The teardrop is taller than wide: the tip reaches (√2 − 1)/2 of the diameter
        /// below the round body — 22 wide draws 26.6 tall, the board's proportions.
        static let teardropAspectRatio: CGFloat = (2.0 + (2.0.squareRoot() - 1)) / 2
    }

    var shape: Shape {
        switch self {
        case .start, .stop, .returnPoint: .circle
        case .end: .teardrop
        case .warehouse, .staffedPickup, .locker: .roundedSquare
        }
    }

    /// Where the mark meets its coordinate on a map: the teardrop's tip *is* the point,
    /// so it anchors at the bottom; every other mark sits centered on it. The badge owns
    /// this knowledge so no caller has to reason about shapes.
    public var mapAnchor: UnitPoint {
        shape == .teardrop ? .bottom : .center
    }

    /// What sits on the shape — the second half of the grayscale test's (shape, glyph)
    /// pair, as data so the pairing is testable.
    nonisolated enum Glyph: Hashable {
        case concentricDot
        case number(Int)
        case symbol(SFSymbol)
    }

    var glyph: Glyph {
        switch self {
        case .start, .end: .concentricDot
        case .stop(let number): .number(number)
        case .returnPoint: .symbol(.arrowUturnBackward)
        case .warehouse: .symbol(.building2Fill)
        case .staffedPickup: .symbol(.storefrontFill)
        case .locker: .symbol(.cabinetFill)
        }
    }

    /// The glyph, drawn. All white — contrast comes from the mark, and the mark's tokens
    /// hold the 3:1 graphics threshold (DesignSystem: shape and glyph carry the role, so
    /// poor contrast loses emphasis, never meaning).
    @ViewBuilder
    fileprivate func glyph(diameter: CGFloat) -> some View {
        switch glyph {
        case .concentricDot:
            Circle().fill(.white)
                .frame(width: diameter * 0.38, height: diameter * 0.38)
        case .number(let number):
            Text(number, format: .number)
                .font(.system(size: diameter * 0.55, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5) // two digits still fit the circle
                .foregroundStyle(.white)
                .padding(diameter * 0.1)
        case .symbol(let symbol):
            Image(systemSymbol: symbol)
                .font(.system(size: diameter * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// The semantic token behind this role (DesignSystem pin table). Return shares the
    /// warehouse's value today but keeps its own entry — meaning gets a token, not a
    /// clever reuse (DesignSystem → the two-entries rule).
    var color: Color {
        switch self {
        case .start: Color(.pointStart)
        case .stop: Color(.pointMid)
        case .end: Color(.pointEnd)
        case .returnPoint: Color(.placeReturn)
        case .warehouse: Color(.placeWarehouse)
        case .staffedPickup: Color(.placePickup)
        case .locker: Color(.placeLocker)
        }
    }

    /// The paired words — the badge never speaks to VoiceOver by shape alone. Localized
    /// in the package bundle so every consumer says exactly the same thing.
    var words: LocalizedStringResource {
        switch self {
        case .start:
            LocalizedStringResource("Pickup", bundle: .kit)
        case .stop(let number):
            LocalizedStringResource("Stop \(number)", bundle: .kit)
        case .end:
            LocalizedStringResource("Drop-off", bundle: .kit)
        case .returnPoint:
            LocalizedStringResource("Return point", bundle: .kit)
        case .warehouse:
            LocalizedStringResource("Warehouse", bundle: .kit)
        case .staffedPickup:
            LocalizedStringResource("Pick-up point", bundle: .kit)
        case .locker:
            LocalizedStringResource("Parcel locker", bundle: .kit)
        }
    }
}

#Preview("The 2c table") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(
            [PointBadge.Role.start, .stop(number: 3), .stop(number: 12), .end,
             .returnPoint, .warehouse, .staffedPickup, .locker],
            id: \.self
        ) { role in
            HStack(spacing: 12) {
                PointBadge(role: role)
                Text(role.words)
            }
        }
    }
    .padding()
}

#Preview("Grayscale column — roles survive color removal") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(
            [PointBadge.Role.start, .stop(number: 3), .end, .returnPoint, .warehouse],
            id: \.self
        ) { role in
            PointBadge(role: role)
        }
    }
    .padding()
    .grayscale(1)
}

#Preview("Compact candidate in a tight row") {
    HStack(spacing: 6) {
        PointBadge(role: .start)
        Text("Москва, ул Москворечье, 6")
            .font(.footnote)
        PointBadge(role: .end)
    }
    .frame(height: 15)
    .padding()
}

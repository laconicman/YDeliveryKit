import SwiftUI

/// The route drawn as a line — a badge per stop threaded by a spine, the address and
/// the door's contact beside each mark. Handoff §6's last component and the `3e`
/// history card's read of an order. Read-only on purpose: interactive stop rows
/// (pick, role menu, warnings) stay their own views — this is how stored routes are
/// *shown*, not how drafts edit them.
public struct RouteLine: View {
    /// One vertex of the drawn route. `role` sets the mark; `title` is the address
    /// line, never truncated (handoff §8 — a wrong address is a failed delivery).
    /// `nonisolated` like every pure value type here (package rule 4).
    public nonisolated struct Stop: Hashable, Sendable {
        public var role: PointBadge.Role
        public var title: String
        /// The contact line when one is aboard — «Иван Петров · +7 912 345-67-89».
        public var subtitle: String?

        public init(role: PointBadge.Role, title: String, subtitle: String? = nil) {
            self.role = role
            self.title = title
            self.subtitle = subtitle
        }
    }

    public let stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    /// A stored route, mapped: position derives the mark — first the ring, last the
    /// teardrop, middles their number (the `2c` mapping) — and the point's contact
    /// summary rides the subtitle. A stored route carries no role column yet
    /// (YDelivery TechDebt YD-15), so position is the honest source.
    public init(points: [RoutePoint]) {
        self.init(stops: Self.stops(from: points))
    }

    /// The `2c` mapping as data, so it is testable without rendering: ends are
    /// symbols, everything between is numbered by position. `nonisolated` — pure
    /// value mapping must not trap off the main actor (Swift Testing's pool).
    public nonisolated static func stops(from points: [RoutePoint]) -> [Stop] {
        points.enumerated().map { index, point in
            Stop(
                role: index == 0
                    ? .start
                    : index == points.count - 1 ? .end : .stop(number: index + 1),
                title: point.address,
                subtitle: point.contactSummary
            )
        }
    }

    /// The badge column's fixed width — the regular mark's diameter, so the spine
    /// aligns under every role and the text column starts at one x.
    static let badgeColumn = PointBadge.regularDiameter
    /// How far the last row's approach spine reaches — the regular mark's height;
    /// the badge's own opaque fill hides the whole segment, so it only bridges.
    static let badgeSlot = PointBadge.regularDiameter
    /// The connector's stroke.
    static let spineWidth: CGFloat = 2
    /// Chrome, not meaning — the shape carries the route, so the spine takes the
    /// subdued token and survives grayscale like the badges do.
    static let spineColor = Color.secondary

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                row(stop, isLast: index == stops.count - 1)
            }
        }
    }

    /// One row: the mark over its spine segment, then address and contact. The spine
    /// is a row background — inter-row rhythm lives inside the row's bottom padding,
    /// so the line stays continuous across it.
    private func row(_ stop: Stop, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: Layout.Spacing.gutter) {
            PointBadge(role: stop.role)
                .frame(width: Self.badgeColumn, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    // Intermediate rows: the spine runs the column edge to edge —
                    // the opaque badge hides the part beneath it, so the line reads
                    // as departing and arriving at the mark. Last row: only the
                    // badge-high approach is drawn, hidden under the mark — the line
                    // arrives at the pin and never hangs past it.
                    Rectangle()
                        .fill(Self.spineColor)
                        .frame(
                            width: Self.spineWidth,
                            height: isLast ? Self.badgeSlot : nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: isLast ? nil : .infinity)
                }
            VStack(alignment: .leading, spacing: Layout.Spacing.hairline) {
                Text(stop.title)
                if let subtitle = stop.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : Layout.Spacing.unit)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("A–Б route") {
    RouteLine(stops: [
        .init(role: .start, title: "Москва, ул Москворечье, 6",
              subtitle: "Иван Петров · +7 912 345-67-89"),
        .init(role: .end, title: "Москва, Каширское шоссе, 52"),
    ])
    .padding()
}

#Preview("Four stops with a return") {
    RouteLine(stops: [
        .init(role: .start, title: "Склад — Санкт-Петербург, Невский, 100",
              subtitle: "Анна Сидорова · +7 998 765-43-21"),
        .init(role: .stop(number: 2), title: "Москва, Тверская, 6"),
        .init(role: .end, title: "Москва, Арбат, 10"),
        .init(role: .returnPoint, title: "Склад — Санкт-Петербург, Невский, 100"),
    ])
    .padding()
}

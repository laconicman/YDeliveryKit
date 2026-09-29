import SFSafeSymbols
import SwiftUI

/// The provider's own account of an order, one line per change — the words the
/// journal keeps (`ProviderEvent.providerStatus`, phrased by `ProviderStatusPhrase`),
/// oldest first, the latest emphasised. It reads what the sync engine already
/// stores and nothing rendered before: the history list's expanded row and the
/// order detail both show the collapsed status; this is the trail behind it.
///
/// The row shape is the callout's per-stop timeline (`PointCallout.Timeline` in
/// the app): a mark, the words, the time — so the two timelines read as one
/// family. Marks: past events are quiet checks, the latest is the accent dot,
/// and a terminal latest wears the status's own glyph.
public struct StatusTimeline: View {
    /// One line of the trail. `words` is already phrased: a status this build
    /// does not know still lands as a timed «Status updated», never a raw wire
    /// word on a surface (the app's YD-7 rule).
    public nonisolated struct Entry: Identifiable, Sendable {
        public var id: UUID
        public var at: Date
        public var words: LocalizedStringResource
        /// The trail's end — delivered or cancelled — drawn with the status glyph.
        public var terminal: OrderStatus?

        public init(id: UUID, at: Date, words: LocalizedStringResource,
                    terminal: OrderStatus? = nil) {
            self.id = id
            self.at = at
            self.words = words
            self.terminal = terminal
        }

        /// Phrased events, oldest first, with consecutive repeats of one status
        /// folded into the first sighting — the journal and a search pass can both
        /// report the same word, and the trail says it once.
        public static func entries(from events: [ProviderEvent]) -> [Entry] {
            var out: [Entry] = []
            var lastStatus: String?
            for event in events.sorted(by: { $0.at < $1.at }) {
                guard let status = event.providerStatus else { continue }
                if status == lastStatus { continue }
                lastStatus = status
                out.append(Entry(
                    id: event.id, at: event.at,
                    words: ProviderStatusPhrase.phrase(for: status)
                        ?? LocalizedStringResource("Status updated", bundle: .kit),
                    terminal: Self.terminalStatus(for: status)))
            }
            return out
        }

        /// Which wire words close the trail. Only the two that end an order for
        /// good — the return leg and «not delivered» stay open, a decision may
        /// still recover them.
        static func terminalStatus(for providerStatus: String) -> OrderStatus? {
            switch providerStatus {
            case "delivered", "delivered_finish": .done
            case "cancelled", "cancelled_with_payment", "cancelled_by_taxi", "cancelled_with_items_on_hands": .cancelled
            default: nil
            }
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(events: [ProviderEvent]) {
        self.init(entries: Entry.entries(from: events))
    }

    public var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Layout.Spacing.tight) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, isLatest: index == entries.count - 1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func row(_ entry: Entry, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.Spacing.unit) {
            mark(for: entry, isLatest: isLatest)
                .frame(width: Self.markColumn)
            Text(entry.words)
                .fontWeight(isLatest ? .medium : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.at, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(isLatest ? .primary : .secondary)
    }

    @ViewBuilder
    private func mark(for entry: Entry, isLatest: Bool) -> some View {
        if isLatest, let terminal = entry.terminal, let symbol = terminal.symbol {
            Image(systemSymbol: symbol)
                .foregroundStyle(terminal.color)
        } else if isLatest {
            Image(systemSymbol: .smallcircleFilledCircleFill)
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemSymbol: .checkmarkCircleFill)
                .foregroundStyle(.secondary)
        }
    }

    /// The mark's column — wide enough for the widest glyph so the words align.
    private static let markColumn: CGFloat = 16
}

#Preview("A live trail") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let order = UUID()
    StatusTimeline(events: [
        ProviderEvent(orderID: order, providerEventID: 1, at: t0, kind: "status", providerStatus: "new", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 2, at: t0 + 40, kind: "status", providerStatus: "accepted", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 3, at: t0 + 131, kind: "status", providerStatus: "performer_lookup", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 4, at: t0 + 420, kind: "status", providerStatus: "performer_found", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 5, at: t0 + 1_200, kind: "status", providerStatus: "pickuped", source: "journal"),
        ProviderEvent(orderID: order, at: t0 + 1_260, kind: "status", providerStatus: "pickuped", source: "search"),
        ProviderEvent(orderID: order, providerEventID: 6, at: t0 + 2_300, kind: "status", providerStatus: "delivery_arrived", source: "journal"),
    ])
    .padding()
}

#Preview("Delivered — the trail closes") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let order = UUID()
    StatusTimeline(events: [
        ProviderEvent(orderID: order, providerEventID: 1, at: t0, kind: "status", providerStatus: "accepted", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 2, at: t0 + 900, kind: "status", providerStatus: "pickuped", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 3, at: t0 + 3_000, kind: "status", providerStatus: "delivered_finish", source: "journal"),
    ])
    .padding()
}

#Preview("An unknown word still keeps its time") {
    StatusTimeline(events: [
        ProviderEvent(orderID: UUID(), providerEventID: 1, at: .now, kind: "status", providerStatus: "some_future_status", source: "journal"),
    ])
    .padding()
}

#Preview("Nothing yet renders nothing") {
    StatusTimeline(events: [])
        .padding()
}

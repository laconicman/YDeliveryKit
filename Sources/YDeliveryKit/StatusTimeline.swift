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
        /// The row's signature verdict — the warnings below ride on it; `nil`,
        /// `.notSigned`, and `.verified` all render quiet.
        public var signatureStatus: SignatureVerdict?
        /// Who last synced a change to this row, per CloudKit — shown only
        /// beside a warning, so a clean trail stays quiet.
        public var modifierName: String?

        public init(id: UUID, at: Date, words: LocalizedStringResource,
                    terminal: OrderStatus? = nil,
                    signatureStatus: SignatureVerdict? = nil,
                    modifierName: String? = nil) {
            self.id = id
            self.at = at
            self.words = words
            self.terminal = terminal
            self.signatureStatus = signatureStatus
            self.modifierName = modifierName
        }

        /// Phrased events, oldest first, with consecutive repeats of one *phrase*
        /// folded into the first sighting — the journal and a search pass can both
        /// report the same word, and `new` → `estimating` → `accepted` are three wire
        /// words for one thing the reader is told («Placing the order»); the trail
        /// says it once, at the time it first became true. The fold keys on phrase
        /// *and* verdict — a repeated sighting that failed its signature check must
        /// not hide behind its verified twin.
        ///
        /// Lives beside the view, not in `YDeliveryData`: the output is a rendering
        /// choice (a `LocalizedStringResource`, a status glyph), while the pure input
        /// — `ProviderStatusPhrase` — already sits in the data target. The day a
        /// non-UI consumer (a snapshot renderer) needs the fold, it moves down.
        public static func entries(from events: [ProviderEvent],
                                   modifierNames: [UUID: String] = [:]) -> [Entry] {
            var out: [Entry] = []
            var lastPhrase: String?
            var lastStatus: SignatureVerdict?
            for event in events.sorted(by: { $0.at < $1.at }) {
                guard let status = event.providerStatus else { continue }
                let words = ProviderStatusPhrase.phrase(for: status)
                    ?? LocalizedStringResource("Status updated", bundle: .kit)
                // The resource's key is the phrase's identity across locales.
                if words.key == lastPhrase, event.signatureStatus == lastStatus {
                    continue
                }
                lastPhrase = words.key
                lastStatus = event.signatureStatus
                out.append(Entry(
                    id: event.id, at: event.at, words: words,
                    terminal: Self.terminalStatus(for: status),
                    signatureStatus: event.signatureStatus,
                    modifierName: event.signatureStatus?.trailWarning == nil
                        ? nil : modifierNames[event.id]))
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

    /// The day and year turns are decided in the calendar and zone the rows are
    /// *formatted* in — the view's environment, not the device's — so a change
    /// that renders as «00:30» on a new day is labelled as one (review, Kit #30).
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    private var displayCalendar: Calendar {
        var calendar = calendar
        calendar.timeZone = timeZone
        return calendar
    }

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
                    row(entry, isLatest: index == entries.count - 1,
                        stamp: stamp(at: index))
                }
            }
        }
    }

    /// How much of the date a row says. Every row has the time; the first row and
    /// every row whose day differs from the one above add the day — two «14:30» a
    /// day apart stay apart — and a row whose *year* differs from the one above
    /// (or, for the first row, from today) adds the year, so a trail that
    /// outlives a calendar never shows two «2 Jan 12:00» twelve months apart.
    private func stamp(at index: Int) -> Stamp {
        let calendar = displayCalendar
        let at = entries[index].at
        let previous = index == 0 ? Date.now : entries[index - 1].at
        // Granularity, not the year number: a calendar with eras (Japanese) reuses
        // year numbers across them, and the compare must see the era too.
        let sameYear = calendar.isDate(at, equalTo: previous, toGranularity: .year)
        if index > 0, calendar.isDate(at, inSameDayAs: previous) { return .time }
        return sameYear ? .day : .dayAndYear
    }

    private enum Stamp {
        case time, day, dayAndYear

        var format: Date.FormatStyle {
            switch self {
            case .time: .dateTime.hour().minute()
            case .day: .dateTime.day().month(.abbreviated).hour().minute()
            case .dayAndYear: .dateTime.day().month(.abbreviated).year().hour().minute()
            }
        }
    }

    /// One change. Each row is its own accessibility element (words, then time),
    /// so VoiceOver walks the trail change by change — `RouteLine` combines at
    /// the row, never the whole line, and this follows it. A failed signature
    /// adds a second line naming the verdict and — where the share discloses
    /// it — the account that synced the change; a clean trail stays quiet.
    private func row(_ entry: Entry, isLatest: Bool, stamp: Stamp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.Spacing.unit) {
            mark(for: entry, isLatest: isLatest)
                .frame(width: Self.markColumn)
            VStack(alignment: .leading, spacing: Layout.Spacing.tight) {
                Text(entry.words)
                    .fontWeight(isLatest ? .medium : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let warning = entry.signatureStatus?.trailWarning {
                    Label(
                        title: {
                            Text(warning)
                                + Text(entry.modifierName.map {
                                    String(localized: LocalizedStringResource(
                                        " · changed by \($0)", bundle: .kit))
                                } ?? "")
                        },
                        icon: { Image(systemSymbol: .exclamationmarkTriangleFill) }
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Text(entry.at, format: stamp.format)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(isLatest ? .primary : .secondary)
        .accessibilityElement(children: .combine)
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

extension SignatureVerdict {
    /// What a non-quiet verdict says beside the row it was read from — `nil`
    /// where the row is trusted or the order never signed, so nothing renders.
    /// The words live on the verdict so the trail and the detail's provider
    /// block phrase one warning one way.
    public nonisolated var trailWarning: LocalizedStringResource? {
        switch self {
        case .unsigned:
            LocalizedStringResource("Not signed by the owner", bundle: .kit)
        case .invalid:
            LocalizedStringResource("Signature does not match", bundle: .kit)
        case .keyChanged:
            LocalizedStringResource("Owner's signing key changed", bundle: .kit)
        case .notSigned, .verified:
            nil
        }
    }
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

#Preview("Across two days — the day shows where it turns") {
    let monday = Date(timeIntervalSince1970: 1_800_000_000)
    let order = UUID()
    StatusTimeline(events: [
        ProviderEvent(orderID: order, providerEventID: 1, at: monday, kind: "status", providerStatus: "accepted", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 2, at: monday + 3_600, kind: "status", providerStatus: "performer_not_found", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 3, at: monday + 86_400, kind: "status", providerStatus: "performer_lookup", source: "journal"),
        ProviderEvent(orderID: order, providerEventID: 4, at: monday + 90_000, kind: "status", providerStatus: "performer_found", source: "journal"),
    ])
    .padding()
}

#Preview("An unknown word still keeps its time") {
    StatusTimeline(events: [
        ProviderEvent(orderID: UUID(), providerEventID: 1, at: .now, kind: "status", providerStatus: "some_future_status", source: "journal"),
    ])
    .padding()
}

#Preview("A signature that failed warns in place") {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let order = UUID()
    let tampered = UUID()
    StatusTimeline(entries: StatusTimeline.Entry.entries(from: [
        ProviderEvent(orderID: order, providerEventID: 1, at: t0, kind: "status", providerStatus: "accepted", source: "journal", signatureStatus: .verified),
        ProviderEvent(id: tampered, orderID: order, providerEventID: 2, at: t0 + 900, kind: "status", providerStatus: "pickuped", source: "journal", signatureStatus: .invalid),
        ProviderEvent(orderID: order, providerEventID: 3, at: t0 + 3_000, kind: "status", providerStatus: "delivered_finish", source: "journal", signatureStatus: .verified),
    ], modifierNames: [tampered: "Irina"]))
        .padding()
}

#Preview("Nothing yet renders nothing") {
    StatusTimeline(events: [])
        .padding()
}

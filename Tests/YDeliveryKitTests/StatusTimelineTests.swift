import Foundation
import Testing
@testable import YDeliveryKit

/// The trail's derivation — the pure half of `StatusTimeline`: ordering, folding,
/// phrasing, and which words close it.
@Suite("Status timeline")
@MainActor
struct StatusTimelineTests {
    private let order = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ status: String, at offset: TimeInterval, id: Int64? = nil,
                       source: String = "journal") -> ProviderEvent {
        ProviderEvent(orderID: order, providerEventID: id, at: t0 + offset,
                      kind: "status", providerStatus: status, source: source)
    }

    @Test("Entries come oldest first whatever order the events arrive in")
    func sortsByTime() {
        let entries = StatusTimeline.Entry.entries(from: [
            event("pickuped", at: 900, id: 2),
            event("accepted", at: 0, id: 1),
        ])
        #expect(entries.map(\.at) == [t0, t0 + 900])
    }

    @Test("A status the journal and a search both report is one line — the first sighting's")
    func foldsConsecutiveRepeats() {
        let entries = StatusTimeline.Entry.entries(from: [
            event("accepted", at: 0, id: 1),
            event("pickuped", at: 900, id: 2),
            event("pickuped", at: 960, source: "search"),
            event("delivery_arrived", at: 2_000, id: 3),
        ])
        #expect(entries.count == 3)
        #expect(entries[1].at == t0 + 900, "the fold keeps the earliest time, not the re-sighting's")
    }

    @Test("Three wire words for one phrase are one line — the fold is on what the reader sees")
    func foldsConsecutivePhrases() {
        let entries = StatusTimeline.Entry.entries(from: [
            event("new", at: 0, id: 1),
            event("estimating", at: 40, id: 2),
            event("accepted", at: 130, id: 3),
            event("performer_lookup", at: 131, id: 4),
        ])
        #expect(entries.count == 2, "«Placing the order» once, then «Looking for a courier»")
        #expect(entries[0].at == t0, "the phrase is stamped when it first became true")
    }

    @Test("A status returning after another is its own line — only *consecutive* repeats fold")
    func keepsNonConsecutiveRepeats() {
        let entries = StatusTimeline.Entry.entries(from: [
            event("performer_lookup", at: 0, id: 1),
            event("performer_found", at: 100, id: 2),
            event("performer_lookup", at: 200, id: 3),
        ])
        #expect(entries.count == 3)
    }

    @Test("Events without a status word are not lines")
    func skipsStatuslessEvents() {
        let price = ProviderEvent(orderID: order, providerEventID: 9, at: t0, kind: "price",
                                  detail: "1200", source: "journal")
        #expect(StatusTimeline.Entry.entries(from: [price]).isEmpty)
    }

    @Test("Only delivered and cancelled close the trail")
    func terminalWords() {
        #expect(StatusTimeline.Entry.terminalStatus(for: "delivered_finish") == .done)
        #expect(StatusTimeline.Entry.terminalStatus(for: "cancelled_with_payment") == .cancelled)
        #expect(StatusTimeline.Entry.terminalStatus(for: "returned") == nil, "a returned parcel is a decision, not an ending")
        #expect(StatusTimeline.Entry.terminalStatus(for: "performer_not_found") == nil)
    }

    @Test("An unknown wire word keeps its time and never reaches the row raw")
    func unknownWordIsPhrased() {
        let entries = StatusTimeline.Entry.entries(from: [event("some_future_status", at: 0, id: 1)])
        #expect(entries.count == 1)
        #expect(String(localized: entries[0].words) == "Status updated")
    }

    @Test("Every wire word the collapse calls a decision carries its own phrase")
    func decisionWordsArePhrased() {
        // `.attention` is six different waits behind one chip — the phrase is the
        // row's only way to say which; a missing one would fall back to the
        // generic «Status updated» and the row would lie by vagueness.
        for word in ["ready_for_approval", "estimating_failed", "performer_not_found",
                     "pay_waiting", "failed", "returned", "returned_finish"] {
            #expect(ProviderStatusPhrase.phrase(for: word) != nil, "\(word) must be phrased")
        }
    }

    @Test("«failed» does not presume a delivery — refused claims wear it too")
    func failedIsHonestForTheNeverDispatched() {
        // One wire word, two truths: refused-at-acceptance (never dispatched) and
        // dispatched-then-died. «Delivery failed» presumed the second; «ended
        // before delivery» is true of both (the drive's seven litter rows).
        #expect(String(localized: ProviderStatusPhrase.phrase(for: "failed")!)
                == "Ended before delivery")
    }
}

import Testing
@testable import YDeliveryKit

@Suite("Order status presentation")
@MainActor
struct StatusChipTests {
    @Test("Only the draft speaks without a glyph")
    func draftAloneLacksGlyph() {
        #expect(OrderStatus.draft.symbol == nil)
        for status in OrderStatus.allCases where status != .draft {
            #expect(status.symbol != nil, "\(status) pairs its color with a glyph — the color never carries meaning alone")
        }
    }

    @Test("Every status has words")
    func everyStatusSpeaks() {
        for status in OrderStatus.allCases {
            #expect(!String(localized: status.words).isEmpty)
        }
    }

    @Test("Glyphs are distinct — a shared glyph would make color load-bearing")
    func glyphsAreDistinct() {
        let symbols = OrderStatus.allCases.compactMap(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("Words are distinct — two statuses may never read the same")
    func wordsAreDistinct() {
        let words = OrderStatus.allCases.map { String(localized: $0.words) }
        #expect(Set(words).count == words.count)
    }

    @Test("The disclosure states are three distinct values — collapsed, expanded, and the in-flight read")
    func disclosureStatesAreDistinct() {
        let states: [StatusChip.Disclosure] = [.collapsed, .expanded, .opening]
        #expect(Set(states).count == states.count)
        // The indicator chip stays the default — a chip that only reports
        // carries no accessory (DesignSystem → "Control roles").
        _ = StatusChip(status: .active)
        _ = StatusChip(status: .active, disclosure: .collapsed)
    }

    @Test("Attention speaks as a decision — «Not delivered» lied for claims never dispatched")
    func attentionSpeaksAsDecision() {
        // A claim parked at `ready_for_approval`/`pay_waiting` was never attempted;
        // a claim refused at acceptance was never dispatched. «Not delivered»
        // presumed a delivery existed — the family word is the wait, not the
        // outcome (the device drive's litter rows).
        #expect(String(localized: OrderStatus.attention.words) == "Needs a decision")
    }
}

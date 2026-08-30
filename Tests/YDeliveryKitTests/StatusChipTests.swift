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
}

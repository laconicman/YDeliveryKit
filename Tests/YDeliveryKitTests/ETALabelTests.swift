import Foundation
import Testing
@testable import YDeliveryKit

/// The duration form is a fixed reading, not a ticking timer (board `5a`,
/// review Kit PR #8): the string derives from the provider's own interval —
/// `etaAt − observedAt` — and renders once.
@Suite("ETALabel.durationString")
struct ETALabelDurationTests {
    @Test("The provider's interval renders, in minutes")
    func rendersTheEstimate() {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let eta = observed.addingTimeInterval(14 * 60)
        let rendered = ETALabel.durationString(at: eta, observedAt: observed)
        #expect(rendered.contains("14"),
                "the vendor's own minutes — \"\(rendered)\"")
    }

    @Test("A lapsed ETA floors at zero — stale, never negative")
    func lapsedFloorsAtZero() {
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        let rendered = ETALabel.durationString(
            at: observed.addingTimeInterval(-120), observedAt: observed)
        #expect(rendered.contains("0"),
                "an ETA in the past is a stale sighting, not a debt — \"\(rendered)\"")
    }

    @Test("Without a stamp the interval freezes against now — once")
    func unstampedFreezesAtRender() {
        let eta = Date.now.addingTimeInterval(14 * 60)
        let rendered = ETALabel.durationString(at: eta, observedAt: nil)
        #expect(rendered.contains("14") || rendered.contains("13"),
                "render-time snapshot of the remaining wait — \"\(rendered)\"")
    }
}

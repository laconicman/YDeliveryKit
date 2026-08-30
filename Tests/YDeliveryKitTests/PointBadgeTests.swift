import Testing
@testable import YDeliveryKit

@Suite("Point badge taxonomy")
@MainActor
struct PointBadgeTests {
    /// One of each role, stop number fixed — the taxonomy under test is the kind, not
    /// the numbering.
    private let allRoles: [PointBadge.Role] = [
        .start, .stop(number: 2), .end, .returnPoint, .warehouse, .staffedPickup, .locker,
    ]

    @Test("The grayscale column holds: every (shape, glyph) pair is unique")
    func rolesSurviveColorRemoval() {
        struct Pair: Hashable {
            let shape: PointBadge.Role.Shape
            let glyph: PointBadge.Role.Glyph
        }
        let pairs = allRoles.map { Pair(shape: $0.shape, glyph: $0.glyph) }
        #expect(Set(pairs).count == pairs.count, "a shared pair would make color load-bearing")
    }

    @Test("Ends are symbols, not letters — and never numbers")
    func endsCarryNoText() {
        #expect(PointBadge.Role.start.glyph == .concentricDot)
        #expect(PointBadge.Role.end.glyph == .concentricDot)
    }

    @Test("A stop's number comes from the datum and survives into the glyph")
    func stopNumberIsTheDatum() {
        #expect(PointBadge.Role.stop(number: 7).glyph == .number(7))
    }

    @Test("Every role has words — the badge never speaks to VoiceOver by shape alone")
    func everyRoleSpeaks() {
        for role in allRoles {
            #expect(!String(localized: role.words).isEmpty)
        }
    }

    @Test("Words are distinct — two roles may never read the same")
    func wordsAreDistinct() {
        let words = allRoles.map { String(localized: $0.words) }
        #expect(Set(words).count == words.count)
    }

    @Test("The teardrop is the one mark taller than wide — the tip is the coordinate")
    func teardropCarriesTheTip() {
        for role in allRoles {
            let isTeardrop = role.shape == .teardrop
            #expect(isTeardrop == (role == .end))
        }
        #expect(PointBadge.Role.Shape.teardropAspectRatio > 1)
    }
}

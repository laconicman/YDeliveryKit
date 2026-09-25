import Foundation
import Testing
import YDeliveryKit

/// The share sheet's extraction rules — what counts as a place in a URL, what
/// counts as an address in a message, and where the door words land.
@Suite("Shared address extraction")
struct SharedAddressTests {
    /// A Maps share URL the way the wire actually sends it — percent-encoded.
    private func mapsURL(_ query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = query
        return try #require(components.url)
    }

    @Test("An Apple Maps link seeds the pin — coordinate, label, address")
    func mapsURLSeeds() throws {
        let url = try mapsURL([
            .init(name: "ll", value: "55.7558,37.6173"),
            .init(name: "q", value: "Кафе «Му-Му»"),
            .init(name: "address", value: "Москва, Петровка, 2"),
        ])
        let seed = try #require(SharedAddress.mapsSeed(from: url))
        #expect(seed.latitude == 55.7558)
        #expect(seed.longitude == 37.6173)
        #expect(seed.name == "Кафе «Му-Му»")
        #expect(seed.address == "Москва, Петровка, 2")
    }

    @Test("The `coordinate` spelling counts too — newer share sheets emit it")
    func mapsCoordinateParam() throws {
        let url = try mapsURL([
            .init(name: "coordinate", value: "55.7,37.5"),
            .init(name: "q", value: "Офис"),
        ])
        let seed = try #require(SharedAddress.mapsSeed(from: url))
        #expect(seed.latitude == 55.7)
        #expect(seed.name == "Офис")
        #expect(seed.address == nil)
    }

    @Test("A link without a coordinate is no place — whatever the host says")
    func noCoordinateIsNoPlace() {
        #expect(SharedAddress.mapsSeed(from:
                URL(string: "https://maps.apple.com/?q=Москва")!) == nil)
        #expect(SharedAddress.mapsSeed(from:
                URL(string: "https://example.com/?ll=55.7,37.5")!) == nil,
                "only Maps' own links claim a pin")
    }

    @Test("A malformed coordinate is no place — the pin is not salvaged")
    func malformedCoordinateIsNil() throws {
        // `ll=55.7,bad,37.5` must not pin "55.7, 37.5" — dropping the bad
        // field puts the marker on a coordinate nobody wrote (review, PR #11).
        let url = try mapsURL([.init(name: "ll", value: "55.7,bad,37.5")])
        #expect(SharedAddress.mapsSeed(from: url) == nil)
    }

    @Test("A bare address line is its own candidate — no detection needed")
    func wholeTextFallback() {
        let candidates = SharedAddress.addressCandidates(
            in: "Каширское шоссе, 52, подъезд 2")
        #expect(candidates.last == "Каширское шоссе, 52, подъезд 2")
    }

    @Test("Detected spans outrank the whole message, which still rides along")
    func detectorFirstWholeLast() {
        let text = "Привезите, пожалуйста, на Каширское шоссе, 52 — к вечеру"
        let candidates = SharedAddress.addressCandidates(in: text)
        #expect(candidates.last == text,
                "the whole message is always the last guess")
        // Whether the detector found a span inside it depends on its own
        // language model — the contract pins only that detected candidates
        // lead and the full text trails.
        if candidates.count > 1 {
            #expect(candidates.first != text)
        }
    }

    @Test("The message's door words land in typed fields, not the address")
    func doorPartsSplit() {
        let parts = SharedAddress.doorParts(
            in: "Каширское шоссе, 52, подъезд 2, кв. 15, домофон 77")
        #expect(parts.entrance == "2")
        #expect(parts.apartment == "15")
        #expect(parts.intercom == "77")
        #expect(parts.floor.isEmpty)
    }

    @Test("Bare and dotted labels both count — «эт 3» and «эт. 3» are one word")
    func doorPartLabelForms() {
        let parts = SharedAddress.doorParts(
            in: "офис 214 на эт. 3, вход с под. Б")
        #expect(parts.apartment == "214")
        #expect(parts.floor == "3")
        #expect(parts.entrance == "Б")
    }

    @Test("A comma does not glue a door label into the value before it")
    func commaSeparatedDoorWords() {
        let parts = SharedAddress.doorParts(in: "кв. 15,домофон 77")
        #expect(parts.apartment == "15",
                "the comma splits — «15,домофон» is no flat number (review, PR #11)")
        #expect(parts.intercom == "77")
    }

    @Test("A message with no door words yields no parts")
    func noDoorWords() {
        #expect(SharedAddress.doorParts(in: "Каширское шоссе, 52").isEmpty)
    }
}

import Testing
import YDeliveryKit

@Suite("RouteLine mapping")
struct RouteLineTests {
    private func point(_ address: String, name: String? = nil, phone: String? = nil) -> RoutePoint {
        RoutePoint(latitude: 55, longitude: 37, address: address,
                   contactName: name, contactPhone: phone)
    }

    @Test("Two points are start and end — ends are symbols, never letters")
    func twoPointsAreEnds() {
        let stops = RouteLine.stops(from: [point("А"), point("Б")])
        #expect(stops.map(\.role) == [.start, .end])
        #expect(stops.map(\.title) == ["А", "Б"])
    }

    @Test("Middle stops are numbered by position, so numbers survive reordering")
    func middlesAreNumbered() {
        let stops = RouteLine.stops(from: [point("А"), point("Б"), point("В"), point("Г")])
        #expect(stops.map(\.role) == [.start, .stop(number: 2), .stop(number: 3), .end])
    }

    @Test("The contact summary rides the subtitle; a bare address drops the line")
    func contactRidesSubtitle() {
        let stops = RouteLine.stops(from: [
            point("А", name: "Иван Петров", phone: "+79123456789"),
            point("Б"),
        ])
        #expect(stops[0].subtitle == "Иван Петров · +79123456789")
        #expect(stops[1].subtitle == nil)
    }

    @Test("A carried role names the mark — the return leg is not a numbered stop")
    func carriedRoleWins() {
        var returnLeg = point("Склад")
        returnLeg.role = .return
        var pickup = point("А")
        pickup.role = .pickup
        var dropoff = point("Б")
        dropoff.role = .dropoff
        let stops = RouteLine.stops(from: [pickup, dropoff, returnLeg])
        #expect(stops.map(\.role) == [.start, .stop(number: 2), .returnPoint])
    }

    @Test("A carried drop-off at the end is still the teardrop")
    func carriedDropoffEnds() {
        var pickup = point("А")
        pickup.role = .pickup
        var dropoff = point("Б")
        dropoff.role = .dropoff
        let stops = RouteLine.stops(from: [pickup, dropoff])
        #expect(stops.map(\.role) == [.start, .end])
    }
}

@Suite("RoutePoint contact summary")
struct RoutePointContactSummaryTests {
    @Test("Components win over the whole string — the formatter owns name order")
    func componentsPreferred() {
        let point = RoutePoint(
            latitude: 0, longitude: 0, address: "А",
            contactName: "Wire Whole",
            contactGivenName: "Иван", contactFamilyName: "Петров")
        #expect(point.contactSummary == "Иван Петров")
    }

    @Test("The wire's whole string is the fallback for component-less rows")
    func wholeNameFallback() {
        let point = RoutePoint(
            latitude: 0, longitude: 0, address: "А", contactName: "Иван Петров")
        #expect(point.contactSummary == "Иван Петров")
    }

    @Test("The extension joins the phone, never the number")
    func extensionJoins() {
        let point = RoutePoint(
            latitude: 0, longitude: 0, address: "А",
            contactPhone: "+79123456789", contactPhoneExtension: "12")
        #expect(point.contactSummary == "+79123456789, ext. 12")
    }

    @Test("A bare extension is not a phone — no dangling dial instruction")
    func extensionWithoutPhoneDrops() {
        let point = RoutePoint(
            latitude: 0, longitude: 0, address: "А", contactPhoneExtension: "12")
        #expect(point.contactSummary == nil)
    }

    @Test("Nothing aboard reads as nil, not an empty line")
    func emptyIsNil() {
        let point = RoutePoint(latitude: 0, longitude: 0, address: "А")
        #expect(point.contactSummary == nil)
    }
}

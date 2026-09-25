import Testing
import YDeliveryKit

/// The widget-surface address rule (board `5e`): a cramped surface sheds the
/// leading city — the one segment constant within a delivery — and nothing else.
@Suite("RoutePoint.compactAddress")
struct CompactAddressTests {
    @Test("A leading city segment drops, street and number stay")
    func cityDrops() {
        let point = RoutePoint(
            latitude: 0, longitude: 0,
            address: "Москва, Каширское шоссе, 52")
        #expect(point.compactAddress == "Каширское шоссе, 52")
    }

    @Test("Door details past the number survive — truncation is the surface's call")
    func doorDetailsStay() {
        let point = RoutePoint(
            latitude: 0, longitude: 0,
            address: "Москва, Николоямская улица, 49с1, подъезд 3")
        #expect(point.compactAddress == "Николоямская улица, 49с1, подъезд 3")
    }

    @Test("A two-part address sheds nothing — «street, number» is already compact")
    func twoPartsStay() {
        let point = RoutePoint(
            latitude: 0, longitude: 0, address: "Каширское шоссе, 52")
        #expect(point.compactAddress == "Каширское шоссе, 52")
    }

    @Test("«street, number, door» has no city — a digit-only second segment vetoes the drop")
    func streetWithDoorStays() {
        let point = RoutePoint(
            latitude: 0, longitude: 0,
            address: "Каширское шоссе, 52, подъезд 3")
        #expect(point.compactAddress == "Каширское шоссе, 52, подъезд 3")
    }

    @Test("A leading segment with digits is a number, not a city — kept")
    func numberedFirstStays() {
        let point = RoutePoint(
            latitude: 0, longitude: 0,
            address: "1-й проезд, Каширское шоссе, 52")
        #expect(point.compactAddress == "1-й проезд, Каширское шоссе, 52")
    }
}

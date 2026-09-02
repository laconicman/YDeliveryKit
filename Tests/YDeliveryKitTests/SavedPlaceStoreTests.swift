import Foundation
import Testing
@testable import YDeliveryKit

@Suite("Saved place store")
struct SavedPlaceStoreTests {
    private let directory: URL
    private let store: SavedPlaceStore

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SavedPlaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavedPlaceStore(directory: directory)
    }

    private var warehouse: SavedPlace {
        SavedPlace(
            name: "Склад на Невском",
            kind: .warehouse,
            point: RoutePoint(
                latitude: 59.932720,
                longitude: 30.349709,
                address: "Санкт-Петербург, Невский проспект, 100",
                addressParts: AddressParts(entrance: "со двора", floor: "1"),
                contactName: "Менеджер склада",
                contactPhone: "+7 495 123-45-67",
                contactPhoneExtension: "123"
            )
        )
    }

    @Test("An empty store reads as no places, not an error")
    func absentFileReadsEmpty() throws {
        #expect(try store.read().isEmpty)
    }

    @Test("A place round-trips whole: parts, contact, extension, kind")
    func roundTrip() throws {
        let place = warehouse
        try store.save(place)
        #expect(try store.read() == [place])
    }

    @Test("Saving the same id updates in place — no duplicate chips")
    func saveUpserts() throws {
        var place = warehouse
        try store.save(place)

        place.name = "Основной склад"
        try store.save(place)

        let places = try store.read()
        #expect(places.count == 1)
        #expect(places[0].name == "Основной склад")
    }

    @Test("Removing forgets the place; removing the absent is not an error")
    func removeForgets() throws {
        let place = warehouse
        try store.save(place)
        try store.remove(id: place.id)
        #expect(try store.read().isEmpty)

        try store.remove(id: place.id)
    }

    @Test("Orders recorded before address parts existed still decode")
    func oldOrdersStillDecode() throws {
        // The slice-1 wire shape, byte for byte: no addressParts, no extension.
        let legacy = Data("""
        [{"created": 778467721.834213,
          "id": "6F9B8B44-9A70-4A2F-8C3A-111111111111",
          "route": [{"address": "Москва, ул Москворечье, 6",
                     "contactName": "Иван Петров",
                     "contactPhone": "+7 912 345-67-89",
                     "latitude": 55.646068,
                     "longitude": 37.668176}],
          "status": "done"}]
        """.utf8)
        try legacy.write(to: directory.appendingPathComponent("orders.json"))

        let orders = try OrderStore(directory: directory).read()
        #expect(orders.count == 1)
        #expect(orders[0].route[0].addressParts == nil)
        #expect(orders[0].route[0].contactPhoneExtension == nil)
    }
}

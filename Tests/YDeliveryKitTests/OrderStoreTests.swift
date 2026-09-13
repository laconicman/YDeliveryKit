import Foundation
import Testing
@testable import YDeliveryKit

@Suite("Order store")
struct OrderStoreTests {
    private let directory: URL
    private let store: OrderStore

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrderStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = OrderStore(directory: directory)
    }

    private var sampleOrder: Order {
        Order(
            created: Date(timeIntervalSince1970: 1_756_500_000),
            status: .done,
            route: [
                RoutePoint(
                    latitude: 55.7558,
                    longitude: 37.6173,
                    address: "Москва, ул Москворечье, 6",
                    contactName: "Иван Петров",
                    contactPhone: "+7 912 345-67-89"
                ),
                RoutePoint(latitude: 55.6460, longitude: 37.6681, address: "Москва, Каширское шоссе, 52"),
            ]
        )
    }

    @Test("An empty store reads as no history, not an error")
    func absentFileReadsEmpty() throws {
        #expect(try store.read().isEmpty)
    }

    @Test("An order round-trips whole: route, contacts, status, creation date")
    func roundTrip() throws {
        let order = sampleOrder
        try store.record(order)
        #expect(try store.read() == [order])
    }

    @Test("Recording keeps earlier orders, newest first")
    func recordAppendsNewestFirst() throws {
        let first = sampleOrder
        var second = sampleOrder
        second.id = UUID()
        second.created = first.created.addingTimeInterval(3600)

        try store.record(first)
        try store.record(second)
        #expect(try store.read() == [second, first])
    }

    @Test("Creation times round-trip exactly, sub-second precision included")
    func datePrecisionSurvives() throws {
        var order = sampleOrder
        order.created = Date(timeIntervalSinceReferenceDate: 778_467_721.834213)
        try store.record(order)
        #expect(try store.read() == [order])
    }

    @Test("Concurrent writers all land — no lost updates")
    func concurrentWritersAllLand() async throws {
        let orders = (0..<16).map { offset in
            var order = sampleOrder
            order.id = UUID()
            order.created = sampleOrder.created.addingTimeInterval(Double(offset))
            return order
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for order in orders {
                group.addTask { [store] in try store.record(order) }
            }
            try await group.waitForAll()
        }
        #expect(Set(try store.read().map(\.id)) == Set(orders.map(\.id)))
    }

    @Test("A corrupt file reads as empty and is not destroyed")
    func corruptFileReadsEmptyAndSurvives() throws {
        let fileURL = directory.appendingPathComponent("orders.json")
        let garbage = Data("not json".utf8)
        try garbage.write(to: fileURL)

        #expect(try store.read().isEmpty)
        #expect(try Data(contentsOf: fileURL) == garbage, "reading must never rewrite the evidence")
    }

    @Test("Recording over corrupt history rescues it aside, byte for byte")
    func recordingRescuesCorruptHistory() throws {
        let garbage = Data("not json".utf8)
        try garbage.write(to: directory.appendingPathComponent("orders.json"))

        let order = sampleOrder
        try store.record(order)

        #expect(try store.read() == [order])
        let rescued = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("orders.corrupted-") }
        #expect(rescued.count == 1)
        #expect(try Data(contentsOf: #require(rescued.first)) == garbage,
                "recording must move the evidence aside, never overwrite it")
    }

    @Test("An unreadable file throws — could not look is not nothing there")
    func unreadableFileThrows() throws {
        let fileURL = directory.appendingPathComponent("orders.json")
        try Data("[]".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)

        #expect(throws: (any Error).self) { try store.read() }
    }

    @Test("Statuses persist as stable strings, not case positions")
    func statusWireFormatIsStable() throws {
        try store.record(sampleOrder)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("orders.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains(#""status" : "done""#))
    }
}

extension OrderStoreTests {
    @Test("Two rescues in one second both land — the evidence never blocks the write")
    func sameSecondRescuesDoNotCollide() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = OrderStore(directory: directory)
        let file = directory.appendingPathComponent("orders.json")

        // Corrupt → write → corrupt → write, faster than one second.
        try Data("not json".utf8).write(to: file)
        try store.record(Order(created: .now, status: .searching, route: []))
        try Data("still not json".utf8).write(to: file)
        try store.record(Order(created: .now, status: .searching, route: []))

        let sidecars = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("orders.corrupted-") }
        #expect(sidecars.count == 2, "both rescues kept their evidence (DeepWiki audit, 2026-09-13)")
    }
}

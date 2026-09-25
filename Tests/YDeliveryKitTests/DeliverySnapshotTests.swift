import Foundation
import Testing
import YDeliveryKit

/// The widget contract's own suite — the file is the whole seam between the
/// app and its extensions, so its rules are pinned here: a tolerant read, an
/// atomic write, a lock-screen-legible protection class, and the render that
/// decides what an extension may show.
@Suite("Delivery snapshot")
struct DeliverySnapshotTests {
    /// Tests cannot mint a real App Group container — `containerURL(for…)`
    /// resolves only under the entitlement — so the store's URL lookup is the
    /// one thing under test via a stand-in FileManager that serves a temp
    /// directory under the group's name.
    private final class ContainerStub: FileManager, @unchecked Sendable {
        let root: URL
        init(root: URL) { self.root = root }
        override func containerURL(
            forSecurityApplicationGroupIdentifier groupIdentifier: String
        ) -> URL? {
            root.appendingPathComponent(groupIdentifier, isDirectory: true)
        }
    }

    private func makeStub() throws -> ContainerStub {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let group = root.appendingPathComponent("group.test", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        return ContainerStub(root: root)
    }

    private func order(status: OrderStatus = .active, claimID: String? = "claim-1")
        -> Order {
        Order(created: .now, status: status,
              route: [
                  RoutePoint(latitude: 0, longitude: 0,
                             address: "Москва, Москворечье, 6"),
                  RoutePoint(latitude: 0, longitude: 0,
                             address: "Москва, Каширское шоссе, 52, кв 12"),
              ],
              claimID: claimID,
              courierName: "Сергей", courierVehicle: "м 234 ор 77",
              etaMinutes: 14, providerStatus: "delivery_arrived",
              providerObservedAt: .now)
    }

    @Test("A written snapshot reads back verbatim")
    func roundTrip() throws {
        let stub = try makeStub()
        let snapshot = DeliverySnapshot(renderedAt: .now, orders: [
            DeliverySnapshot.Entry(order: order(), orderNumber: "4417"),
        ])
        try DeliverySnapshotStore.write(snapshot, inAppGroup: "group.test",
                                        fileManager: stub)
        let read = DeliverySnapshotStore.read(inAppGroup: "group.test",
                                              fileManager: stub)
        #expect(read?.orders.count == 1)
        #expect(read?.orders.first?.orderNumber == "4417")
        #expect(read?.orders.first?.courierName == "Сергей")
        #expect(read?.snapshotVersion == DeliverySnapshot.currentVersion)
    }

    @Test("Absent and malformed files read as empty, never a throw")
    func tolerantRead() throws {
        let stub = try makeStub()
        #expect(DeliverySnapshotStore.read(inAppGroup: "group.test",
                                           fileManager: stub) == nil,
                "no file is the first-run surface")
        let url = stub.root.appendingPathComponent("group.test")
            .appendingPathComponent(DeliverySnapshotStore.filename)
        try Data("not json".utf8).write(to: url)
        #expect(DeliverySnapshotStore.read(inAppGroup: "group.test",
                                           fileManager: stub) == nil,
                "a torn write is a rendering to redo, not a crash")
        #expect(DeliverySnapshotStore.read(inAppGroup: "group.missing",
                                           fileManager: stub) == nil,
                "an unresolvable group is empty too")
    }

    @Test("A write leaves a complete file where the group expects it")
    func writeLandsAtomically() throws {
        let stub = try makeStub()
        try DeliverySnapshotStore.write(
            DeliverySnapshot(renderedAt: .now, orders: []),
            inAppGroup: "group.test", fileManager: stub)
        let url = stub.root.appendingPathComponent("group.test")
            .appendingPathComponent(DeliverySnapshotStore.filename)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The `.completeUntilFirstUserAuthentication` attribute the write sets
        // is device behaviour — the simulator's macOS filesystem stores no
        // protection class, so there is nothing here to assert beyond "the
        // write does not fail when it asks".
    }

    @Test("The render decides liveness — a claimed order mid-story is live")
    func liveMembership() {
        #expect(DeliverySnapshot.Entry(order: order(status: .active),
                                       orderNumber: nil).isLive)
        #expect(DeliverySnapshot.Entry(order: order(status: .attention),
                                       orderNumber: nil).isLive,
                "a parked decision still rides the widget")
        #expect(!DeliverySnapshot.Entry(order: order(status: .done),
                                        orderNumber: nil).isLive)
        #expect(!DeliverySnapshot.Entry(order: order(status: .active, claimID: nil),
                                        orderNumber: nil).isLive,
                "a local draft is never a widget row")
    }

    @Test("Addresses render compact; the dedup key keeps the full identity")
    func compactRender() {
        let entry = DeliverySnapshot.Entry(order: order(), orderNumber: "4417")
        #expect(entry.pickupAddress == "Москворечье, 6")
        #expect(entry.destinationAddress == "Каширское шоссе, 52, кв 12")
        #expect(entry.destinationKey?
                .contains("москва, каширское шоссе, 52") == true,
                "the dedup key keeps the full address the label sheds")
    }
}

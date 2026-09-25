import Foundation
import Testing
import YDeliveryKit

/// The share handoff's file contract — same rules as the snapshot, plus the
/// one that makes it a slot: consume answers once and clears.
@Suite("Shared draft")
struct SharedDraftTests {
    /// Tests cannot mint a real App Group container — `containerURL(for…)`
    /// resolves only under the entitlement — so the store's URL lookup is the
    /// one thing under test via a stand-in FileManager serving a temp dir
    /// (the same stunt `DeliverySnapshotTests` pulls).
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
            .appendingPathComponent("SharedDraftTests-\(UUID().uuidString)", isDirectory: true)
        let group = root.appendingPathComponent("group.test", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        return ContainerStub(root: root)
    }

    private func draft(end: SharedDraft.End = .dropoff) -> SharedDraft {
        SharedDraft(
            sharedAt: .now,
            point: RoutePoint(
                latitude: 55.65, longitude: 37.66,
                address: "Москва, Каширское шоссе, 52",
                addressParts: AddressParts(entrance: "2", apartment: "15")),
            end: end,
            otherEnd: RoutePoint(
                latitude: 55.75, longitude: 37.6,
                address: "Санкт-Петербург, Невский проспект, 1",
                contactName: "Склад"))
    }

    @Test("A written draft consumes back verbatim — and only once")
    func consumeIsOnce() throws {
        let stub = try makeStub()
        try SharedDraftStore.write(draft(), inAppGroup: "group.test", fileManager: stub)

        let read = SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub)
        #expect(read?.end == .dropoff)
        #expect(read?.point.addressParts?.entrance == "2")
        #expect(read?.otherEnd?.contactName == "Склад")

        #expect(SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub) == nil,
                "the slot answers once — a replayed activation must not reopen the draft")
        #expect(!SharedDraftStore.hasPending(inAppGroup: "group.test", fileManager: stub))
    }

    @Test("Absent, torn, and future-versioned files all consume as nil")
    func tolerantConsume() throws {
        let stub = try makeStub()
        #expect(SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub) == nil)
        #expect(SharedDraftStore.consume(inAppGroup: "group.missing", fileManager: stub) == nil,
                "an unresolvable group is empty too")

        let url = stub.root.appendingPathComponent("group.test")
            .appendingPathComponent(SharedDraftStore.filename)
        try Data("not json".utf8).write(to: url)
        #expect(SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub) == nil,
                "a torn handoff reads as absent — the sender can share again")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "and the spoiled file goes with it — it could only ever answer nil")

        var newer = draft()
        newer.draftVersion = SharedDraft.currentVersion + 1
        try SharedDraftStore.write(newer, inAppGroup: "group.test", fileManager: stub)
        #expect(SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub) == nil,
                "a bumped version is the writer saying a meaning changed — guessing is worse")
    }

    @Test("A second share replaces the first — the slot holds the latest ask")
    func latestWins() throws {
        let stub = try makeStub()
        try SharedDraftStore.write(draft(end: .pickup), inAppGroup: "group.test",
                                   fileManager: stub)
        try SharedDraftStore.write(draft(end: .dropoff), inAppGroup: "group.test",
                                   fileManager: stub)
        #expect(SharedDraftStore.consume(inAppGroup: "group.test", fileManager: stub)?.end
                == .dropoff)
    }
}

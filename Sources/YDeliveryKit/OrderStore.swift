import Foundation

/// File-backed storage for completed orders and their points — the one substrate recents,
/// saved places, and repeat-order all read (Design → "A point carries data, not
/// coordinates"). Lives in the App Group container from day one so widgets read it
/// directly; retrofitting that later is the expensive version of this decision
/// (DESIGN-HANDOFF §6).
///
/// **Provisional by design.** One JSON file, atomically replaced on write: the cheapest
/// stack that makes the App Group location real. The Phase-2 schema-and-stack research
/// (the app's <doc:Roadmap>) replaces the format; `Order`'s spine and this type's
/// *location* are what survive it.
///
/// Reads and writes run under `NSFileCoordinator`: the file is shared with future
/// extension processes (widget, share-in), and coordination is what makes the
/// read-prepend-replace in ``record(_:)`` one transaction across threads *and*
/// processes — `.atomic` alone only prevents torn files, not lost updates.
///
/// `nonisolated`, like the app's `TokenStore`: no UI affinity, no in-memory state — a
/// widget timeline or background refresh reads it off the main actor. The app-side
/// `@Observable` controller that owns an instance arrives with the first screen that
/// renders orders (Phase 2).
public nonisolated struct OrderStore: Sendable {
    /// One group, shared by the app and every future extension target. The suffix
    /// matches the app's bundle identifier.
    public static let appGroupID = "group.com.learnable.YDelivery"

    private let fileURL: URL

    /// A store rooted in the given directory. Injectable so tests write into a
    /// temporary directory, never the real container.
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("orders.json")
    }

    /// The store every production reader shares — app, widget, activity. `nil` when the
    /// container cannot be resolved (entitlement missing or not yet provisioned): a state
    /// for the caller to render, never a crash (CLAUDE.md rule 3).
    public static func inAppGroup(fileManager: FileManager = .default) -> OrderStore? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map(OrderStore.init(directory:))
    }

    /// Every stored order, newest first. Absence reads as empty — a first launch has no
    /// history. A malformed file also reads as empty rather than crashing; its bytes are
    /// never touched by reading, and ``record(_:)`` rescues them aside rather than
    /// overwriting, so nothing is destroyed silently.
    ///
    /// Throws when coordination fails *or the file exists but cannot be read* (I/O,
    /// permissions): *could not look* is not *nothing there*, and history rendering as
    /// suddenly empty would be a lie. The caller renders the failure (CLAUDE.md rule 3).
    public func read() throws -> [Order] {
        var coordinationError: NSError?
        var outcome: Result<Stored, any Error> = .success(.absent)
        NSFileCoordinator().coordinate(
            readingItemAt: fileURL,
            options: [],
            error: &coordinationError
        ) { url in
            outcome = Result { try Self.load(from: url) }
        }
        if let coordinationError { throw coordinationError }
        switch try outcome.get() {
        case .absent, .malformed: return []
        case .orders(let orders): return orders
        }
    }

    /// Appends one order and persists the whole set atomically, under write coordination
    /// so concurrent writers queue instead of overwriting each other's history. Existing
    /// history it cannot decode is moved aside as `orders.corrupted-<t>.json` — recording
    /// stays possible, and the evidence stays recoverable. Throws rather than degrading
    /// silently — history that did not persist is a state the caller must see.
    public func record(_ order: Order) throws {
        var coordinationError: NSError?
        var accessError: (any Error)?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { url in
            do {
                let existing: [Order]
                switch try Self.load(from: url) {
                case .absent:
                    existing = []
                case .orders(let orders):
                    existing = orders
                case .malformed:
                    try Self.rescueCorruptFile(at: url)
                    existing = []
                }
                let data = try Self.encoder.encode([order] + existing)
                try data.write(to: url, options: .atomic)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
    }

    /// What the file held: distinguishing *nothing there* from *unreadable as orders* —
    /// the two must never collapse into one another (review, PR #12).
    private enum Stored {
        case absent
        case orders([Order])
        case malformed
    }

    private static func load(from url: URL) throws -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        }
        guard let orders = try? decoder.decode([Order].self, from: data) else {
            return .malformed
        }
        return .orders(orders)
    }

    /// Moves undecodable history aside, timestamped, in the same directory. A same-second
    /// collision makes the move — and with it the `record` — throw, which still loses
    /// nothing.
    private static func rescueCorruptFile(at url: URL) throws {
        let rescueName = "orders.corrupted-\(Int(Date.now.timeIntervalSince1970)).json"
        let rescueURL = url.deletingLastPathComponent().appendingPathComponent(rescueName)
        try FileManager.default.moveItem(at: url, to: rescueURL)
    }

    /// Sorted keys keep the file diffable and stable across runs — it will be migrated
    /// by hand exactly once, when the Phase-2 stack lands. Dates stay Foundation's
    /// native seconds-since-reference doubles: exact round-trip beats a readable
    /// timestamp in a file only machines read — ISO 8601 truncates sub-second precision,
    /// and a stored order must compare equal to the one that was recorded.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

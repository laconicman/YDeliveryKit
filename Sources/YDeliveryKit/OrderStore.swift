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
    /// history. A corrupt file also reads as empty rather than crashing; the bytes stay
    /// on disk untouched until the next `record`, so nothing is destroyed silently.
    public func read() -> [Order] {
        var orders: [Order] = []
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: nil) { url in
            orders = Self.decode(from: url)
        }
        return orders
    }

    /// Appends one order and persists the whole set atomically, under write coordination
    /// so concurrent writers queue instead of overwriting each other's history. Throws
    /// rather than degrading silently — history that did not persist is a state the
    /// caller must see.
    public func record(_ order: Order) throws {
        var coordinationError: NSError?
        var accessError: (any Error)?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { url in
            do {
                let data = try Self.encoder.encode([order] + Self.decode(from: url))
                try data.write(to: url, options: .atomic)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
    }

    private static func decode(from url: URL) -> [Order] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Order].self, from: data)) ?? []
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

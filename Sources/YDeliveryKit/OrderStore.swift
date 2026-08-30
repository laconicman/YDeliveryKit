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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([Order].self, from: data)) ?? []
    }

    /// Appends one order and persists the whole set atomically. Throws rather than
    /// degrading silently — history that did not persist is a state the caller must see.
    public func record(_ order: Order) throws {
        let orders = [order] + read()
        let data = try Self.encoder.encode(orders)
        try data.write(to: fileURL, options: .atomic)
    }

    /// ISO 8601 dates and sorted keys: the file stays diffable and stable across runs —
    /// it will be migrated by hand exactly once, when the Phase-2 stack lands.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

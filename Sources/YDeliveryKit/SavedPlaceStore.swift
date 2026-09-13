import Foundation

/// File-backed storage for saved places — the second reading of the one substrate
/// (recents, saved places, repeat), beside ``OrderStore`` in the App Group container.
///
/// **Provisional by design**, exactly like `OrderStore`: one JSON file, atomically
/// replaced under `NSFileCoordinator`, replaced wholesale by the Phase-2 schema-and-stack
/// research. The coordination discipline is deliberately the same shape as `OrderStore`'s
/// rather than an abstraction over both — two provisional files do not earn a generic
/// store (the research replaces this format; an abstraction would only harden it).
public nonisolated struct SavedPlaceStore: Sendable {
    private let fileURL: URL

    /// A store rooted in the given directory. Injectable so tests write into a
    /// temporary directory, never the real container.
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("places.json")
    }

    /// The store every production reader shares. The App Group is the consuming app's
    /// to name; this package serves any of them. `nil` when the container cannot be
    /// resolved — a state for the caller to render, never a crash.
    public static func inAppGroup(id: String, fileManager: FileManager = .default) -> SavedPlaceStore? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: id)
            .map(SavedPlaceStore.init(directory:))
    }

    /// Every saved place, in the order they were kept. Absence reads as empty; a
    /// malformed file also reads as empty rather than crashing — its bytes are rescued
    /// aside by the next write, never silently destroyed.
    public func read() throws -> [SavedPlace] {
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
        case .places(let places): return places
        }
    }

    /// Inserts or updates one place (by id) and persists the whole set atomically,
    /// under write coordination. Undecodable history moves aside as
    /// `places.corrupted-<t>-<id>.json`; saving stays possible, the evidence recoverable.
    public func save(_ place: SavedPlace) throws {
        try mutate { places in
            if let index = places.firstIndex(where: { $0.id == place.id }) {
                places[index] = place
            } else {
                places.append(place)
            }
        }
    }

    /// Removes a place. Removing what is already absent is not an error.
    public func remove(id: SavedPlace.ID) throws {
        try mutate { places in
            places.removeAll { $0.id == id }
        }
    }

    private func mutate(_ change: (inout [SavedPlace]) -> Void) throws {
        var coordinationError: NSError?
        var accessError: (any Error)?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { url in
            do {
                var places: [SavedPlace]
                switch try Self.load(from: url) {
                case .absent:
                    places = []
                case .places(let existing):
                    places = existing
                case .malformed:
                    try Self.rescueCorruptFile(at: url)
                    places = []
                }
                change(&places)
                let data = try Self.encoder.encode(places)
                try data.write(to: url, options: .atomic)
            } catch {
                accessError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
    }

    private enum Stored {
        case absent
        case places([SavedPlace])
        case malformed
    }

    private static func load(from url: URL) throws -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        }
        guard let places = try? decoder.decode([SavedPlace].self, from: data) else {
            return .malformed
        }
        return .places(places)
    }

    private static func rescueCorruptFile(at url: URL) throws {
        // Sub-second uniqueness: two rescues in one second must both land — a name
        // collision would fail the very write that tried to preserve the evidence
        // (DeepWiki audit, 2026-09-13).
        let rescueName = "places.corrupted-\(Date.now.timeIntervalSince1970)-\(UUID().uuidString.prefix(8)).json"
        let rescueURL = url.deletingLastPathComponent().appendingPathComponent(rescueName)
        try FileManager.default.moveItem(at: url, to: rescueURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

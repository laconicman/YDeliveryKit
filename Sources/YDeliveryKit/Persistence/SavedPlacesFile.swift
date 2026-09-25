import Foundation

/// The saved places, exported for the share extension's «Откуда» row —
/// `saved-places.json` at the App Group root. The extension never opens the
/// database (Schema → the widget contract), so the places a share could name
/// publish beside the deliveries snapshot, written by the app after each
/// healthy read.
///
/// Same judgement calls as the snapshot: a rendering, not a schema — torn or
/// unreadable bytes read as *empty* (the row simply hides), writes are atomic,
/// and nothing rescues a spoiled file because the app's next read rewrites it.
public nonisolated enum SavedPlacesFile {
    public static let filename = "saved-places.json"

    /// The extension's read. `[]` covers no group, no file, and torn bytes —
    /// an extension renders *absent*, never crashes.
    public static func read(inAppGroup id: String,
                            fileManager: FileManager = .default) -> [SavedPlace] {
        guard let url = url(inAppGroup: id, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedPlace].self, from: data)) ?? []
    }

    /// The app's publish — atomic, first-unlock readable for the same
    /// locked-device reason as the snapshot (review, Kit PR #9).
    public static func write(_ places: [SavedPlace], inAppGroup id: String,
                             fileManager: FileManager = .default) throws {
        guard let url = url(inAppGroup: id, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(places).write(to: url, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication,
        ])
    }

    private static func url(inAppGroup id: String,
                            fileManager: FileManager) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent(filename)
    }
}

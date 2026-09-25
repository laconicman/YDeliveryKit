import Foundation

/// What the share extension hands the app — board `5d`'s "ways in": a Maps
/// place or an address found in chat text becomes a draft with that point
/// filled. The payload is *resolved* before it lands: the extension geocodes
/// or carries the shared coordinate, so the app consumes a `RoutePoint`,
/// never raw text it would have to re-interpret.
///
/// The file is a slot, not a queue — a second share replaces whatever waits,
/// and consuming clears it. Like `DeliverySnapshot` the bytes rescue nothing:
/// a torn handoff is worth less than an absent one, and the sender can always
/// share again.
public nonisolated struct SharedDraft: Codable, Sendable {
    /// Bump when a field's *meaning* changes; additive fields decode on old
    /// readers without one.
    public static let currentVersion = 1

    public var draftVersion: Int
    /// When the extension wrote this — the app's "shared at" line if it ever
    /// needs one, and the stale-file diagnostic.
    public var sharedAt: Date
    /// The point the shared text or place resolved to, door parts aboard when
    /// the message spelled them.
    public var point: RoutePoint
    /// Which end of the route the shared point fills — «Это точка доставки»
    /// by default, flippable to the origin in the extension.
    public var end: End
    /// The other end's point when the extension's place row chose a saved
    /// place — resolved there (contact aboard), so consuming needs no join
    /// against the places table.
    public var otherEnd: RoutePoint?

    public nonisolated enum End: String, Codable, Sendable {
        case pickup
        case dropoff
    }

    public init(sharedAt: Date, point: RoutePoint, end: End,
                otherEnd: RoutePoint? = nil,
                draftVersion: Int = SharedDraft.currentVersion) {
        self.draftVersion = draftVersion
        self.sharedAt = sharedAt
        self.point = point
        self.end = end
        self.otherEnd = otherEnd
    }
}

/// `shared-draft.json` at the App Group root — the only channel a share
/// extension has into the app's controllers. The database file *lives* in the
/// group, but the extension's contract is these flat files only — a suspended
/// process holding a SQLite lock is a watchdog termination, so nothing but
/// the app ever opens it (Schema → the widget contract). `consume` is
/// read-and-clear: the slot answers once, so a replayed activation or a
/// stale file cannot open the same draft twice.
public nonisolated enum SharedDraftStore {
    public static let filename = "shared-draft.json"

    /// The extension's write — atomic, first-unlock readable so a share on a
    /// locked device still lands (the snapshot's `write` option set, same
    /// reason).
    public static func write(_ draft: SharedDraft, inAppGroup id: String,
                             fileManager: FileManager = .default) throws {
        guard let url = url(inAppGroup: id, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(draft).write(to: url, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication,
        ])
    }

    /// The app's read — and the slot's clear. `nil` covers every unreadable
    /// case — no group, no file, torn bytes, a version this app predates —
    /// and the file is removed either way: a consumed draft must not replay,
    /// and a spoiled one can only ever answer `nil`.
    ///
    /// The slot is claimed by rename first: a share landing between the read
    /// and the removal writes a fresh file under the well-known name, and a
    /// consumed draft must take only its own bytes away (review, PR #11).
    public static func consume(inAppGroup id: String,
                               fileManager: FileManager = .default) -> SharedDraft? {
        guard let url = url(inAppGroup: id, fileManager: fileManager),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        let claimed = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).consumed")
        guard let _ = try? fileManager.moveItem(at: url, to: claimed) else { return nil }
        defer { try? fileManager.removeItem(at: claimed) }
        guard let data = try? Data(contentsOf: claimed) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let draft = try? decoder.decode(SharedDraft.self, from: data),
              draft.draftVersion <= SharedDraft.currentVersion
        else { return nil }
        return draft
    }

    /// Whether a draft waits — the activation sweep's cheap check, so the
    /// common case (nothing shared) costs one stat, not a parse.
    public static func hasPending(inAppGroup id: String,
                                  fileManager: FileManager = .default) -> Bool {
        url(inAppGroup: id, fileManager: fileManager).map {
            fileManager.fileExists(atPath: $0.path)
        } ?? false
    }

    private static func url(inAppGroup id: String,
                            fileManager: FileManager) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent(filename)
    }
}

import CryptoKit
import Foundation

extension UUID {
    /// Deterministic identity — RFC 4122 UUIDv5: SHA-1 over a namespace UUID's bytes
    /// plus the name's UTF-8, first 16 bytes with version 5 and variant bits set.
    ///
    /// The schema's dedup mechanism (doc:Schema): a replayed journal event, a
    /// re-discovered claim, or a retried migration re-derives the *same* id, so the
    /// second write merges by primary key instead of duplicating — no secondary
    /// UNIQUE constraint, which `SyncEngine` rejects on synchronized tables anyway.
    public nonisolated static func derived(namespace: UUID, _ components: String...) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: withUnsafeBytes(of: namespace.uuid) { Data($0) })
        hasher.update(data: Data(components.joined(separator: "|").utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// This app's derivation namespace — distinct per derivation kind, so a stop and
    /// an event derived from the same parts can never collide.
    public nonisolated enum DerivedNamespace {
        /// Migrated/recorded route children: `orderID ‖ kind ‖ index`.
        public static let orderChild = UUID(uuidString: "7D1E0A3E-5B4C-4A2F-9C8D-1E2F3A4B5C6D")!
        /// Discovered orders: `providerAccountRef ‖ claimID`.
        public static let discoveredOrder = UUID(uuidString: "8E2F1B4F-6C5D-4B3A-AD9E-2F3A4B5C6D7E")!
        /// Provider events: `orderID ‖ providerEventID` or `orderID ‖ status ‖ source`.
        public static let providerEvent = UUID(uuidString: "9F3A2C5A-7D6E-4C4B-BEAF-3A4B5C6D7E8F")!
        /// The discovery-retry queue: `providerAccountRef ‖ claimID`.
        public static let pendingDiscovery = UUID(uuidString: "AF4B3D6B-8E7F-4D5C-CFB0-4B5C6D7E8F9A")!
        /// Lost-answer acceptances: `providerAccountRef ‖ claimID`.
        public static let pendingAcceptance = UUID(uuidString: "C2D5E8F9-A0B1-4C6D-BE2F-7A8B9C0D1E2F")!
        /// Sender-owned field values: `orderID ‖ fieldRef`.
        public static let orderCustomField = UUID(uuidString: "B1C4D7E8-9F0A-4B5C-AD1E-6F7A8B9C0D1E")!
        /// Draft field values: `draftID ‖ fieldRef` — the same derivation, one tier down.
        public static let draftCustomField = UUID(uuidString: "D3E6A1B2-5C7D-4E8F-9A0B-1C2D3E4F5A6B")!
    }
}

import Foundation

/// One entry in a shared order's chat — the only stream a participant may
/// write (doc:Schema → `OrderMessage`). Text notes, photos, and structured
/// kinds (`receptionConfirmed`) are all the same row: a human event in the
/// stream, never a provider truth — «Ирина отметила: получено» renders
/// alongside the provider's `delivered`, not instead of it.
///
/// Append-only is the contract, not a constraint SQLite can state: nothing
/// calls `UPDATE` on the stream, and the audit fallback for a rewritten row
/// is the record's `lastModifiedBy`, not a trigger.
public struct OrderMessage: Codable, Hashable, Identifiable, Sendable {
    /// Caller-held, not derived: a retried post reuses the caller's id and the
    /// `ON CONFLICT REPLACE` default lands the same row — an at-least-once tap
    /// stays one message.
    public var id: UUID
    public var orderID: Order.ID
    public var sentAt: Date
    /// Open vocabulary, stored verbatim — a kind this version doesn't know
    /// still renders as a timestamped line (see ``Kind``).
    public var kind: String
    public var text: String?
    /// A photo message's payload — a value reference (never a FK): the
    /// attachment must name this same order, enforced at the write boundary
    /// since `PRAGMA foreign_keys` is off.
    public var attachmentRef: OrderAttachment.ID?
    /// The display name the post carried — a cache for rendering. Real
    /// attribution is the record's `createdBy`, which SQL can't read; the
    /// hint is what survives an account's departure.
    public var authorHint: String?

    /// The kinds this app writes. Kept as names rather than a closed enum so
    /// a newer peer's kind decodes instead of failing — same rule as
    /// `ProviderEvent.kind`'s open vocabulary.
    public enum Kind {
        public static let text = "text"
        public static let photo = "photo"
        /// «Получение подтверждено» — the receiver's own mark, human truth.
        public static let receptionConfirmed = "receptionConfirmed"
    }

    public init(
        id: UUID = UUID(), orderID: Order.ID, sentAt: Date = Date(),
        kind: String, text: String? = nil,
        attachmentRef: OrderAttachment.ID? = nil, authorHint: String? = nil
    ) {
        self.id = id
        self.orderID = orderID
        self.sentAt = sentAt
        self.kind = kind
        self.text = text
        self.attachmentRef = attachmentRef
        self.authorHint = authorHint
    }
}

/// A parcel photo's metadata — its bytes live one child down in
/// `attachmentBlobs` so the message list never drags image data
/// (doc:Schema). Participants may add: a receiver documenting condition is
/// the product story.
public struct OrderAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var orderID: Order.ID
    /// `photo` today; open like ``OrderMessage.kind``.
    public var kind: String
    public var caption: String?
    public var byteSize: Int64?
    public var createdAt: Date
    public var authorHint: String?

    public init(
        id: UUID = UUID(), orderID: Order.ID, kind: String = "photo",
        caption: String? = nil, byteSize: Int64? = nil,
        createdAt: Date = Date(), authorHint: String? = nil
    ) {
        self.id = id
        self.orderID = orderID
        self.kind = kind
        self.caption = caption
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.authorHint = authorHint
    }
}

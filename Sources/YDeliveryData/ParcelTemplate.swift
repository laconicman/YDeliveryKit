import Foundation

/// A reusable «What's inside» — the sender's parcel library (doc:Roadmap →
/// "the sender's library"). Private tier like ``SavedPlace``: the vocabulary
/// syncs to the owner's devices and never rides a per-order share — an order's
/// parcels stay `OrderItem`s; this only *authors* them.
///
/// `items` holds one entry today — the editor writes a single parcel row — but
/// `parcelTemplateItems` carries `position` from day one, so growing the editor
/// into a bundle is a UI widening, not a migration: read the singleton as the
/// editor's convention, never the type's invariant.
public struct ParcelTemplate: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The chip's label — seeded from the item's own name at save, free to
    /// diverge after: it belongs to the library entry, not the goods it
    /// describes.
    public var name: String
    /// Pinned templates lead the draft's chip row — pin ≈ favourite, the same
    /// ruling ``SavedPlace.pinned`` carries (doc:Roadmap).
    public var pinned: Bool
    /// In display order — `parcelTemplateItems.position` on disk, ``Order.route``'s
    /// convention.
    public var items: [Item]

    public init(id: UUID = UUID(), name: String, pinned: Bool = false,
                items: [Item]) {
        self.id = id
        self.name = name
        self.pinned = pinned
        self.items = items
    }

    /// One parcel row — ``OrderDraft.Item``'s fields minus the two journey refs,
    /// which are route-relative and cannot live in a library entry.
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name = ""
        public var quantity = 1
        public var weightKg: Double?
        /// Declared value as a decimal-precision string — the ``OrderDraft.Item``
        /// discipline: binary float would round money on the way in and out.
        public var cost: String?
        /// ISO 4217 — no default: the writer names its currency, a package
        /// constant would bind the library to one market (as on `OrderItemRow`).
        public var currency: String
        public var sizeLengthCm: Double?
        public var sizeWidthCm: Double?
        public var sizeHeightCm: Double?

        public init(
            id: UUID = UUID(), name: String = "", quantity: Int = 1,
            weightKg: Double? = nil, cost: String? = nil, currency: String,
            sizeLengthCm: Double? = nil, sizeWidthCm: Double? = nil,
            sizeHeightCm: Double? = nil
        ) {
            self.id = id
            self.name = name
            self.quantity = quantity
            self.weightKg = weightKg
            self.cost = cost
            self.currency = currency
            self.sizeLengthCm = sizeLengthCm
            self.sizeWidthCm = sizeWidthCm
            self.sizeHeightCm = sizeHeightCm
        }
    }
}

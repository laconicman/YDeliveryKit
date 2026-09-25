import Foundation

/// One slot in the sender's field schema — the organization-level settings
/// «Ваши поля» edits (board `4b`). Every draft shows the configured fields
/// pre-typed; a completed order keeps the *values* (see `OrderCustomField`).
///
/// The schema is synced to the owner's devices but never shared — it lives in
/// the private tier (`customFieldDefinitions`), while the values it types ride
/// on the order itself (`orderCustomFields`, shared tier).
public nonisolated struct CustomFieldDefinition: Codable, Hashable, Identifiable, Sendable {
    /// What a typed answer looks like — the draft renders a text field or a picker.
    public enum Kind: String, Codable, Sendable {
        case text
        case choice
    }

    /// Where a value rides toward the provider, if anywhere. The substrate names
    /// the *role*; the controller maps each role onto a wire field, so the schema
    /// stays provider-neutral (doc:Schema → custom fields). Each carrier admits
    /// **one** claimant — the store refuses a second definition claiming a slot
    /// already taken, because two fields competing for one wire key cannot both
    /// win.
    public enum Carrier: String, Codable, Sendable, CaseIterable {
        /// App-local metadata — searchable history and Spotlight only.
        case none
        /// The claim's accompanying document — one per claim
        /// (Yandex: `shipping_document` on `ClaimCreateRequest`).
        case claimDocument
        /// The sender's own order number — rides on every destination point and
        /// doubles as the provider-side search filter
        /// (Yandex: `external_order_id` on route points and in `claims/search`).
        case orderNumber
        /// Per-item external tag (Yandex: `extra_id` on cargo items).
        case itemTag
    }

    public var id: UUID
    /// The label the draft and history show — «Заказ», «Платёж», «Накладная».
    public var name: String
    public var kind: Kind
    /// The picker's options — meaningful only for `.choice`.
    public var choices: [String]
    /// Whether the order may leave without a value (board `4b` `isOptional`).
    public var isOptional: Bool
    /// Whether the draft shows it immediately or behind «Добавить поле».
    ///
    /// Invariant: `!isOptional ⇒ isShownByDefault` — a required field the sender
    /// cannot see is a trap: the order blocks on a value nothing asks for. The
    /// editor explains; the store normalizes on write.
    public var isShownByDefault: Bool
    public var carrier: Carrier
    /// Definition order — the draft and the settings list both read it.
    public var position: Int

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .text,
        choices: [String] = [],
        isOptional: Bool = true,
        isShownByDefault: Bool = true,
        carrier: Carrier = .none,
        position: Int = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.choices = choices
        self.isOptional = isOptional
        self.isShownByDefault = isShownByDefault
        self.carrier = carrier
        self.position = position
    }
}

/// A sender-owned value on a placed order — the shared tier, so collaborators
/// read the same «Заказ 4417» the owner sees (doc:Schema → custom fields).
///
/// `fieldRef` is a value, not an FK: the schema it points into is private-tier,
/// and a value must outlive its definition — deleting «Накладная» from settings
/// cannot erase «Накладная 77» off last month's delivery. `name` and `carrier`
/// are the snapshots that render and identify when the definition is gone —
/// and `carrier` specifically is what lets a *collaborator* read the order
/// number: their tier never sees `customFieldDefinitions`, so a join that
/// needs it returns nothing (review, Kit PR #8; TechDebt YD-17).
public nonisolated struct OrderCustomField: Codable, Hashable, Identifiable, Sendable {
    /// Derived: `orderID ‖ fieldRef` — a replayed write merges, never duplicates.
    public var id: UUID
    public var orderID: Order.ID
    public var fieldRef: CustomFieldDefinition.ID
    public var name: String
    public var value: String
    /// The definition's carrier at write time — copied, not joined, for the
    /// same reason `name` snapshots: the slot this value claimed is a fact
    /// about the order's history, not about today's schema.
    public var carrier: CustomFieldDefinition.Carrier?

    public init(orderID: Order.ID, fieldRef: CustomFieldDefinition.ID, name: String,
                value: String, carrier: CustomFieldDefinition.Carrier? = nil) {
        self.id = UUID.derived(
            namespace: UUID.DerivedNamespace.orderCustomField,
            orderID.uuidString, fieldRef.uuidString)
        self.orderID = orderID
        self.fieldRef = fieldRef
        self.name = name
        self.value = value
        self.carrier = carrier
    }
}

import Foundation

/// One stop of an order's route, as the store remembers it: where, spelled how, and who
/// stands at the door. This is what «Repeat» refills and what recents/saved places read —
/// one substrate, not three features (Design → "A point carries data, not coordinates").
///
/// Provisional (Phase 1): address parts, roles, and default options arrive with the
/// Phase-2 schema research; this carries only what the shipped picker can already produce.
public nonisolated struct RoutePoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    /// The address as the courier will read it — the sender may have corrected the
    /// geocoder's proposal, and that correction is exactly what must survive.
    public var address: String

    /// How to get to the door once at the building. Optional and additive: files
    /// written before this field decode with it absent.
    public var addressParts: AddressParts?

    /// Who hands over or receives at this stop — the formatted whole, what the wire and
    /// legacy rows speak.
    public var contactName: String?
    /// The name's components, stored explicitly: Foundation's name parser returns `nil`
    /// for Cyrillic («Иван Петров», verified 2026-09-06), so a stored single string
    /// cannot be split back in this app's first market. Explicit fields concatenated by
    /// the formatter are the robust direction (author's standing preference); these are
    /// additive, and rows written before them still decode.
    public var contactGivenName: String?
    public var contactFamilyName: String?
    public var contactPhone: String?
    /// Dialled after the phone connects — its own field, never folded into the number.
    public var contactPhoneExtension: String?

    public init(
        latitude: Double,
        longitude: Double,
        address: String,
        addressParts: AddressParts? = nil,
        contactName: String? = nil,
        contactGivenName: String? = nil,
        contactFamilyName: String? = nil,
        contactPhone: String? = nil,
        contactPhoneExtension: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.addressParts = addressParts
        self.contactName = contactName
        self.contactGivenName = contactGivenName
        self.contactFamilyName = contactFamilyName
        self.contactPhone = contactPhone
        self.contactPhoneExtension = contactPhoneExtension
    }
}

nonisolated extension RoutePoint {
    /// The collapsed contact line — «Иван Петров · +7 912 345-67-89, ext. 12». The
    /// name prefers the stored components, joined by the formatter so order stays
    /// the locale's decision; `contactName` is the fallback for wire-born rows that
    /// never had components. `nil` when nothing is aboard, so a row drops the line
    /// rather than render an empty one. The extension dials after connect — folded
    /// into the phone with "ext.", never into the number itself.
    public var contactSummary: String? {
        var components = PersonNameComponents()
        components.givenName = contactGivenName
        components.familyName = contactFamilyName
        let formatted = components.formatted()
        let name = formatted.isEmpty ? (contactName ?? "") : formatted
        let phone = if let contactPhoneExtension, !contactPhoneExtension.isEmpty,
                       let contactPhone, !contactPhone.isEmpty {
            String(localized: "\(contactPhone), ext. \(contactPhoneExtension)",
                   bundle: .module)
        } else {
            contactPhone ?? ""
        }
        let summary = [name, phone].filter { !$0.isEmpty }.joined(separator: " · ")
        return summary.isEmpty ? nil : summary
    }
}

/// The parts of an address the geocoder cannot know: how to get to the door once the
/// courier is at the building — and `building`, the строение/корпус the pin can never
/// resolve (the wire takes it as its own field; the house number itself stays inside
/// `fullname`). UI vocabulary here; the wire's names (`building`, `porch`, `sflat`,
/// `sfloor`, `door_code`) appear only at the controller boundary. All strings — an
/// entrance is «А» as often as «2» (DesignSystem → "Field taxonomy": units belong to the
/// field, and no free-text number ever means two things).
public nonisolated struct AddressParts: Codable, Hashable, Sendable {
    /// Строение/корпус — the building's own sub-designation, not the way in. It maps
    /// to the wire's `building`, never folded into the address line (YD-10).
    public var building: String
    public var entrance: String
    public var floor: String
    public var apartment: String
    public var intercom: String

    public init(
        building: String = "",
        entrance: String = "",
        floor: String = "",
        apartment: String = "",
        intercom: String = ""
    ) {
        self.building = building
        self.entrance = entrance
        self.floor = floor
        self.apartment = apartment
        self.intercom = intercom
    }

    /// Tolerant decode: blobs written before a field arrived (the legacy JSON
    /// stores, older share payloads) carry no `building` key, and a synthesized
    /// `decode` would read that as corruption rather than absence.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        building = try container.decodeIfPresent(String.self, forKey: .building) ?? ""
        entrance = try container.decodeIfPresent(String.self, forKey: .entrance) ?? ""
        floor = try container.decodeIfPresent(String.self, forKey: .floor) ?? ""
        apartment = try container.decodeIfPresent(String.self, forKey: .apartment) ?? ""
        intercom = try container.decodeIfPresent(String.self, forKey: .intercom) ?? ""
    }

    /// Nothing filled — rows render the invitation, not an empty summary.
    public var isEmpty: Bool {
        building.isEmpty && entrance.isEmpty && floor.isEmpty
            && apartment.isEmpty && intercom.isEmpty
    }
}

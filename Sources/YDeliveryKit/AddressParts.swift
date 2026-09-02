/// The parts of an address the geocoder cannot know: how to get to the door once the
/// courier is at the building. UI vocabulary here; the wire's names (`porch`, `sflat`,
/// `sfloor`, `door_code`) appear only at the controller boundary. All strings — an
/// entrance is «А» as often as «2» (DesignSystem → "Field taxonomy": units belong to the
/// field, and no free-text number ever means two things).
public nonisolated struct AddressParts: Codable, Hashable, Sendable {
    public var entrance: String
    public var floor: String
    public var apartment: String
    public var intercom: String

    public init(
        entrance: String = "",
        floor: String = "",
        apartment: String = "",
        intercom: String = ""
    ) {
        self.entrance = entrance
        self.floor = floor
        self.apartment = apartment
        self.intercom = intercom
    }

    /// Nothing filled — rows render the invitation, not an empty summary.
    public var isEmpty: Bool {
        entrance.isEmpty && floor.isEmpty && apartment.isEmpty && intercom.isEmpty
    }
}

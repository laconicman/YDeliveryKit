import Foundation

/// What the share sheet pulls out of whatever the sender dropped on it —
/// board `5d`'s "адрес из чата". Pure functions so the extraction rules are
/// testable without the extension; the geocoding that resolves a candidate
/// into a `RoutePoint` stays a runtime service on the extension's side.
public nonisolated enum SharedAddress {
    /// A Maps-style share: the pin's coordinate plus whatever words it came
    /// with. `name` is the pin's label — a place's name as often as an
    /// address — and `address` the postal string when the source knew it.
    public struct MapsSeed: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var name: String?
        public var address: String?

        public init(latitude: Double, longitude: Double,
                    name: String? = nil, address: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
            self.address = address
        }
    }

    /// The seed a shared URL carries, or `nil` when the URL is no map's.
    /// `maps.apple.com` links spell the pin `ll=` or `coordinate=` (both are
    /// seen in the wild), the label `q=`, and the postal line `address=`.
    /// Anything without a coordinate is just a URL, not a place.
    public static func mapsSeed(from url: URL) -> MapsSeed? {
        guard url.host(percentEncoded: false) == "maps.apple.com",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let value = { name in query.first(where: { $0.name == name })?.value }
        // Every component must parse: dropping a bad field and pinning what's
        // left would put the marker on a coordinate nobody wrote (PR #11).
        let coordinate = (value("ll") ?? value("coordinate"))?
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let pair = coordinate, pair.count == 2,
              let latitude = pair[0], let longitude = pair[1]
        else { return nil }
        return MapsSeed(
            latitude: latitude, longitude: longitude,
            name: value("q"), address: value("address"))
    }

    /// Address candidates in shared text, best-first: the detector's address
    /// spans, then the whole trimmed message — a chat line that *is* the
    /// address needs no detection, and a miss costs one wasted geocode, not
    /// the share. Deduped, order preserved.
    public static func addressCandidates(in text: String) -> [String] {
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.address.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        var candidates = (detector?.matches(in: text, range: range) ?? [])
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whole.isEmpty, !candidates.contains(whole) {
            candidates.append(whole)
        }
        return candidates
    }

    /// The door details a message spelled out — «подъезд 2, кв. 15, домофон 77»
    /// — as typed fields, because the wire carries `porch`/`sflat`/`sfloor`/
    /// `door_code` separately and folding them into `fullname` is how they get
    /// lost (the draft's `AddressParts` taxonomy). Label-anchored: a known
    /// detail word takes the word after it as the value.
    public static func doorParts(in text: String) -> AddressParts {
        // Commas and semicolons are separators, not word edges: «кв. 15,домофон
        // 77» must not glue `15,домофон` into the apartment (review, PR #11).
        let words = text
            .components(separatedBy: .whitespacesAndNewlines
                .union(.init(charactersIn: ",;")))
            .filter { !$0.isEmpty }
        var parts = AddressParts()
        for (index, word) in words.enumerated() {
            guard let field = Field(label: word), index + 1 < words.count else { continue }
            let value = words[index + 1]
            guard !value.isEmpty else { continue }
            switch field {
            case .building where parts.building.isEmpty: parts.building = value
            case .entrance where parts.entrance.isEmpty: parts.entrance = value
            case .floor where parts.floor.isEmpty: parts.floor = value
            case .apartment where parts.apartment.isEmpty: parts.apartment = value
            case .intercom where parts.intercom.isEmpty: parts.intercom = value
            default: continue
            }
        }
        return parts
    }

    /// Which `AddressParts` field a label fills. Dotted and bare spellings
    /// both count («кв.»/«кв», «эт.»/«эт») — the label set the app's address
    /// rules already speak (`PickedPlace.namesAHouseNumber`), mapped onto
    /// fields here rather than shared, because the two questions differ:
    /// that one asks *what a number is*, this one *where a detail goes*.
    private enum Field {
        case building, entrance, floor, apartment, intercom

        init?(label: String) {
            switch label.lowercased() {
            // «дом»/«д.»/«владение» stay out: they name the house number itself,
            // which lives in the address — `building` is the строение/корпус
            // sub-designation, the wire's own slot (YD-10). Bare «к» stays out
            // for the same reason `PickedPlace.buildingLabels` excludes it —
            // it is the preposition *to* as often as корпус.
            case "корпус", "корп.", "корп", "строение", "стр.", "стр", "к.",
                 "building", "bldg", "bldg.":
                self = .building
            case "подъезд", "под.", "под", "парадная", "entrance":
                self = .entrance
            case "этаж", "эт.", "эт", "floor":
                self = .floor
            case "квартира", "кв.", "кв", "офис", "apt", "flat", "suite":
                self = .apartment
            case "домофон", "intercom":
                self = .intercom
            default:
                return nil
            }
        }
    }
}

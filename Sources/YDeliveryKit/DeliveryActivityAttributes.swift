import ActivityKit
import Foundation

/// The Live Activity's shared schema (board `5d`). One definition in the Kit
/// because the type must compile identically in the app (which starts and
/// updates the activity) and the widget extension (which renders it) —
/// ActivityKit matches attributes by name and module, so two copies would be
/// two activities.
///
/// `nonisolated`: a plain value payload — the update path runs off the main
/// actor inside the activity lifecycle.
///
/// Identity is deliberately *not* the claim id: the sender's order is the
/// thing they can find again, and a claim swap mid-delivery should retarget
/// the same Lock Screen card, not orphan it.
public nonisolated struct DeliveryActivityAttributes: ActivityAttributes {
    /// The order this activity tracks — fixed for the activity's life, so it
    /// lives on the attributes, not the state.
    public var orderID: UUID

    /// What the Lock Screen and Dynamic Island re-render on each update.
    /// Everything time-sensitive lives here — the attributes are immutable
    /// once the activity starts.
    public struct ContentState: Codable, Hashable, Sendable {
        /// The shared six-state vocabulary (`OrderStatus`), not the vendor's
        /// zoo — the island and lock screen render the same chip the app does.
        public var status: OrderStatus
        /// The sender's own number («4417»), resolved at update time — it can
        /// change if the sender edits their fields, so it is state, not static.
        public var orderNumber: String?
        /// Where the parcel is going, already shortened for a cramped surface
        /// (`RoutePoint.compactAddress` — «Каширское шоссе, 52», city shed).
        public var destinationAddress: String
        /// The courier's first name once the vendor reports one — nil until
        /// `performer_found` and again if the performer info never arrives.
        public var courierName: String?
        /// The courier's vehicle as the vendor spelled it — «м 234 ор 77».
        public var courierVehicle: String?
        /// The wire's own status word — the surface's phase vocabulary:
        /// «едет к получателю» and «у двери» collapse to the same `.active`
        /// in `status`, and the Lock Screen's headline is the difference.
        public var providerStatus: String?
        /// The arrival moment (`Order.etaAt`), recomputed by the updater from
        /// the vendor's `eta` minutes *as observed at* `providerObservedAt` —
        /// absolute so the system can render it without polling us.
        public var etaAt: Date?
        /// When the vendor last said anything — the staleness stamp the
        /// surface must show so a dead activity never looks live (the shared
        /// "provider freshness, always" contract).
        public var providerObservedAt: Date?
        /// The recipient's phone — board `5a`'s «Получателю» button dials the
        /// person at the destination door. (The courier's own number is one
        /// the wire never sends — `performer_info` carries name and vehicle
        /// only — so «Курьеру» has nothing to dial and the surface omits it.)
        public var destinationPhone: String?

        public init(
            status: OrderStatus,
            orderNumber: String? = nil,
            destinationAddress: String,
            courierName: String? = nil,
            courierVehicle: String? = nil,
            providerStatus: String? = nil,
            etaAt: Date? = nil,
            providerObservedAt: Date? = nil,
            destinationPhone: String? = nil
        ) {
            self.status = status
            self.orderNumber = orderNumber
            self.destinationAddress = destinationAddress
            self.courierName = courierName
            self.courierVehicle = courierVehicle
            self.providerStatus = providerStatus
            self.etaAt = etaAt
            self.providerObservedAt = providerObservedAt
            self.destinationPhone = destinationPhone
        }
    }

    public init(orderID: UUID) {
        self.orderID = orderID
    }
}

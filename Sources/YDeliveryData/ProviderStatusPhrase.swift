import Foundation

/// The wire's status word as a short surface phrase — «pickuped» → «Забрал».
/// Every surface that shows provider truth speaks this vocabulary: the Live
/// Activity's headline, the widget's status line, the intent's spoken answer.
///
/// It lives in the package because the widget extension cannot import the app,
/// and the collapsed `OrderStatus` cannot serve instead — «едет к получателю»
/// and «у двери» are both `.active`, and the Lock Screen's headline is exactly
/// that difference. The table is display vocabulary, not policy: which words
/// earn a *banner* is `StatusAnnouncement`'s narrower list on the app side.
///
/// An unknown word returns `nil` — a new wire spelling degrades to the
/// collapsed status words, never to a crash and never to the raw enum.
public enum ProviderStatusPhrase {
    /// The phrase for a wire status spelling, or nil for one we don't know.
    public static func phrase(for providerStatus: String) -> LocalizedStringResource? {
        switch providerStatus {
        case "new", "estimating", "accepted":
            LocalizedStringResource("Placing the order", bundle: .data)
        case "performer_lookup", "performer_draft":
            LocalizedStringResource("Looking for a courier", bundle: .data)
        case "performer_found":
            LocalizedStringResource("Courier assigned — heading to pickup", bundle: .data)
        case "pickup_arrived":
            LocalizedStringResource("Courier is at the pickup door", bundle: .data)
        case "ready_for_pickup_confirmation":
            LocalizedStringResource("Confirming pickup", bundle: .data)
        case "pickuped":
            LocalizedStringResource("Picked up", bundle: .data)
        case "delivery_arrived":
            LocalizedStringResource("Courier is at the destination door", bundle: .data)
        case "ready_for_delivery_confirmation":
            LocalizedStringResource("Confirming delivery", bundle: .data)
        case "returning":
            LocalizedStringResource("Heading back to the sender", bundle: .data)
        case "return_arrived":
            LocalizedStringResource("Back at the pickup point", bundle: .data)
        case "ready_for_return_confirmation":
            LocalizedStringResource("Confirming the return", bundle: .data)
        case "delivered", "delivered_finish":
            LocalizedStringResource("Delivered", bundle: .data)
        case "performer_not_found":
            LocalizedStringResource("No courier found", bundle: .data)
        case "ready_for_approval":
            LocalizedStringResource("Waiting for your approval", bundle: .data)
        case "estimating_failed":
            LocalizedStringResource("Couldn't price the route", bundle: .data)
        case "pay_waiting":
            LocalizedStringResource("Waiting for payment", bundle: .data)
        case "failed":
            LocalizedStringResource("Delivery failed", bundle: .data)
        case "cancelled", "cancelled_with_payment", "cancelled_by_taxi",
             "cancelled_with_items_on_hands":
            LocalizedStringResource("Cancelled", bundle: .data)
        case "returned", "returned_finish":
            LocalizedStringResource("Returned to the sender", bundle: .data)
        default:
            nil
        }
    }
}

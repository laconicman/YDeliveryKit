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
public nonisolated enum ProviderStatusPhrase {
    /// The phrase for a wire status spelling, or nil for one we don't know.
    public static func phrase(for providerStatus: String) -> LocalizedStringResource? {
        switch providerStatus {
        case "new", "estimating", "accepted":
            LocalizedStringResource("Placing the order", bundle: .kit)
        case "performer_lookup", "performer_draft":
            LocalizedStringResource("Looking for a courier", bundle: .kit)
        case "performer_found":
            LocalizedStringResource("Courier assigned — heading to pickup", bundle: .kit)
        case "pickup_arrived":
            LocalizedStringResource("Courier is at the pickup door", bundle: .kit)
        case "ready_for_pickup_confirmation":
            LocalizedStringResource("Confirming pickup", bundle: .kit)
        case "pickuped":
            LocalizedStringResource("Picked up", bundle: .kit)
        case "delivery_arrived":
            LocalizedStringResource("Courier is at the destination door", bundle: .kit)
        case "ready_for_delivery_confirmation":
            LocalizedStringResource("Confirming delivery", bundle: .kit)
        case "returning":
            LocalizedStringResource("Heading back to the sender", bundle: .kit)
        case "return_arrived":
            LocalizedStringResource("Back at the pickup point", bundle: .kit)
        case "ready_for_return_confirmation":
            LocalizedStringResource("Confirming the return", bundle: .kit)
        case "delivered", "delivered_finish":
            LocalizedStringResource("Delivered", bundle: .kit)
        case "performer_not_found":
            LocalizedStringResource("No courier found", bundle: .kit)
        case "ready_for_approval":
            LocalizedStringResource("Waiting for your approval", bundle: .kit)
        case "estimating_failed":
            LocalizedStringResource("Couldn't price the route", bundle: .kit)
        case "pay_waiting":
            LocalizedStringResource("Waiting for payment", bundle: .kit)
        case "failed":
            LocalizedStringResource("Delivery failed", bundle: .kit)
        case "cancelled", "cancelled_with_payment", "cancelled_by_taxi",
             "cancelled_with_items_on_hands":
            LocalizedStringResource("Cancelled", bundle: .kit)
        case "returned", "returned_finish":
            LocalizedStringResource("Returned to the sender", bundle: .kit)
        default:
            nil
        }
    }
}

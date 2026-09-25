import SwiftUI

/// The sender's own order number, formatted once (board `5e`): «Заказ №4417»
/// at regular and expanded, the bare «№4417» at compact. The number is the
/// *sender's* vocabulary — «4417» is what they typed in «Ваши поля» and what
/// a notification title must say beside a customer's chat; the vendor's claim
/// id never reaches this label.
///
/// The caller resolves the number (`StoreController.orderNumber(for:)` or the
/// same join in an extension) — this component only formats. `nil` still
/// reads «Заказ»: an order with no sender number is an order, not a blank.
public struct OrderIdentity: View {
    let number: String?
    let size: SurfaceSize

    public init(number: String?, size: SurfaceSize = .regular) {
        self.number = number
        self.size = size
    }

    public var body: some View {
        Text(words)
    }

    private var words: LocalizedStringResource {
        switch (size, number) {
        case (.compact, let number?):
            // The «№» sign carries "order" — the compact form's only affordance.
            LocalizedStringResource("No. \(number)", bundle: .kit)
        case (_, let number?):
            LocalizedStringResource("Order No. \(number)", bundle: .kit)
        case (_, nil):
            LocalizedStringResource("Order", bundle: .kit)
        }
    }
}

#Preview("Every size") {
    VStack(alignment: .leading, spacing: 8) {
        OrderIdentity(number: "4417", size: .compact)
        OrderIdentity(number: "4417")
        OrderIdentity(number: nil)
    }
    .padding()
}

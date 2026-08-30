/// Where an order stands, in the sender's vocabulary — the six states of the DesignSystem
/// status table. This is the shared vocabulary every surface renders from (app rows,
/// widgets, notifications), not the vendor's status zoo: controllers collapse the wire's
/// many statuses into these when mapping into app models.
///
/// `nonisolated`: plain value vocabulary with no UI affinity — widget timelines and
/// background sync read it off the main actor.
public nonisolated enum OrderStatus: CaseIterable, Hashable, Sendable {
    /// Nothing sent — the draft exists only on this device.
    case draft
    /// Waiting for a courier to take the order.
    case searching
    /// A courier is working the order, on plan.
    case active
    /// Delivered — the successful final state.
    case done
    /// Closed without delivering; the sender has to decide what happens next.
    /// Reserved for decisions: a network failure is a retry, not attention
    /// (DesignSystem → "Semantic colors").
    case attention
    /// Closed, undelivered, nothing left to decide.
    case cancelled
}

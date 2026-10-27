import Foundation

/// Who may write which kind of row (the app's Collaboration → "Verdicts and
/// entitlement", the matrix). CloudKit grants write access per share, not per
/// table, so a read-write participant *can* insert an order event; entitlement is
/// judged at read, not enforced at write (rule 7), and a correctly signed row by a
/// party outside the matrix renders as written by someone who may not write it.
/// On a host the same table is enforced at upload as well.
public enum Entitlement {
    /// Whether `role` may write a row of `table`; `legRef` is the row's leg, `nil` for
    /// the order's own platform leg and the `placed` event.
    ///
    /// Members (receiver, dispatcher, participant) write the chat, photos and ratings;
    /// a courier additionally writes the events of its own leg; the owner writes
    /// anything, memberships and legs included. `participantKeys` answers false here
    /// for everyone: a key row is entitled only to the party its binding names, which
    /// is the binding's own check, not a role's.
    public static func mayWrite(_ role: Party.Role, table: String, legRef: UUID?) -> Bool {
        let memberWritable = [
            OrderMessageRow.tableName, OrderAttachmentRow.tableName, OrderRatingRow.tableName,
        ]
        switch role {
        case .owner:
            return table != ParticipantKeyRow.tableName
        case .member:
            return memberWritable.contains(table)
        case .courier(let leg):
            return table == OrderEventRow.tableName ? legRef == leg : memberWritable.contains(table)
        case .unknown:
            return false
        }
    }
}

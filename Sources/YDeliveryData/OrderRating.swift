import Foundation

/// One rating in a shared order — a signed, append-only fact in its own table, not a
/// message kind (the app's Vision → "Players, trust and reputation"): a rating is
/// aggregated and has a structured subject, and the chat renders it as an event row
/// beside the messages rather than storing it as one.
///
/// "Only the last one counts" is a read-time selection, never a write: posting again
/// appends a row, the effective rating per (author, subject) is the latest by `at`,
/// and the earlier rows stay as that rating's history (``EffectiveRatings``).
public struct OrderRating: Codable, Hashable, Identifiable, Sendable {
    /// Caller-held, never derived: a rating is a *decision* (the app's Collaboration →
    /// rule 1), so two equal ratings are two rows and nothing dedupes them. A retried
    /// post reuses the caller's id and the store's `INSERT OR IGNORE` leaves the first
    /// row standing.
    public var id: UUID
    public var orderID: Order.ID
    /// The leg the rating is written from — the context a courier's entitlement is
    /// judged in, as on an event — not what it rates: a `leg` subject names the rated
    /// leg in ``Subject/ref``. Stored and signed; legs themselves are a later stage, so
    /// nothing reads it yet beyond entitlement.
    public var legRef: UUID?
    /// The writer's party — a `partyRef`, `nil` until the device knows itself
    /// (doc:Schema → "`partyRef`").
    public var authorRef: UUID?
    public var subject: Subject
    /// 1 to 5 (``scores``); the writer refuses anything else.
    public var score: Int
    public var comment: String?
    public var at: Date

    /// The scores a rating may carry.
    public static let scores = 1...5

    /// What a rating is about: `kind` names what `ref` points at, `label` is the
    /// writer's snapshot for rendering (a courier's name and vehicle) — signed with the
    /// row, but never an identity.
    public struct Subject: Codable, Hashable, Sendable {
        /// Open vocabulary, stored verbatim (see ``Kind``).
        public var kind: String
        /// A `party` subject's `partyRef` as a UUID string, a `provider` subject's
        /// `providerAccounts.key`, a `leg` subject's logical leg `ref`, a `stop`
        /// subject's stop id.
        public var ref: String
        public var label: String?

        /// The kinds this app writes. Kept as names rather than a closed enum so a
        /// newer peer's kind decodes instead of failing — the ``OrderMessage/Kind``
        /// rule.
        public enum Kind {
            /// A courier's run.
            public static let leg = "leg"
            /// A person in the order — the receiver, the owner.
            public static let party = "party"
            /// How one door went.
            public static let stop = "stop"
            /// A provider account.
            public static let provider = "provider"
        }

        public init(kind: String, ref: String, label: String? = nil) {
            self.kind = kind
            self.ref = ref
            self.label = label
        }
    }

    public init(
        id: UUID = UUID(), orderID: Order.ID, legRef: UUID? = nil, authorRef: UUID? = nil,
        subject: Subject, score: Int, comment: String? = nil, at: Date = Date()
    ) {
        self.id = id
        self.orderID = orderID
        self.legRef = legRef
        self.authorRef = authorRef
        self.subject = subject
        self.score = score
        self.comment = comment
        self.at = at
    }
}

/// One order's ratings as they count: the effective rating per (author, subject) with
/// its history, and beside them every row whose verdict keeps it from counting —
/// returned, never dropped (the app's Collaboration → rule 6: verdicts render beside
/// the data).
public struct EffectiveRatings: Sendable {
    /// One entry per (author, subject) among the rows that read *verified* or
    /// *legacy*, oldest effective row first.
    public var counted: [EffectiveRating]
    /// Every other row — *unsigned*, *invalid*, *untrustedKey*, *notEntitled*,
    /// *unverifiable* — oldest first, for the UI to show as not counted.
    public var notCounted: [Attested<OrderRating>]

    /// Selects from one order's attested rows. The author is the party the verdict
    /// names, falling back to the row's `authorRef` on a legacy row; rows naming no
    /// author at all group as one unattributed author — a verified row names none only
    /// when it is this device's own, written before the device knew its party, so the
    /// group is one writer revising, and splitting it would count a revision twice.
    /// The effective row is the latest
    /// `at`, on a tie the smallest id (lowercased `uuidString`, as every tie in the
    /// store), so every device selects the same one.
    public init(_ attested: [Attested<OrderRating>]) {
        var groups: [GroupKey: [Attested<OrderRating>]] = [:]
        var notCounted: [Attested<OrderRating>] = []
        for row in attested {
            switch row.verdict {
            case .verified, .legacy:
                let key = GroupKey(
                    author: row.verdict.author?.ref ?? row.value.authorRef,
                    kind: row.value.subject.kind, ref: row.value.subject.ref)
                groups[key, default: []].append(row)
            case .unsigned, .invalid, .untrustedKey, .notEntitled, .unverifiable:
                notCounted.append(row)
            }
        }
        counted = groups.map { key, rows in
            let ordered = rows.sorted { Self.precedes($0.value, $1.value) }
            return EffectiveRating(author: key.author, current: ordered[ordered.count - 1],
                                   history: Array(ordered.dropLast()))
        }
        .sorted { Self.precedes($0.current.value, $1.current.value) }
        self.notCounted = notCounted.sorted { Self.precedes($0.value, $1.value) }
    }

    private struct GroupKey: Hashable {
        var author: UUID?
        var kind: String
        var ref: String
    }

    /// `a` ranks below `b`: the earlier `at`, on a tie the *larger* id — so the
    /// latest row with the smallest id ranks last and is the one in force.
    static func precedes(_ a: OrderRating, _ b: OrderRating) -> Bool {
        guard a.at == b.at else { return a.at < b.at }
        return a.id.uuidString.lowercased() > b.id.uuidString.lowercased()
    }
}

/// The rating in force for one (author, subject) in one order, with the rows it
/// superseded.
public struct EffectiveRating: Identifiable, Sendable {
    /// The party the group belongs to; `nil` for unattributed legacy rows.
    public var author: UUID?
    /// The latest row — the one that counts.
    public var current: Attested<OrderRating>
    /// The earlier rows of the same author and subject, oldest first.
    public var history: [Attested<OrderRating>]

    public var id: OrderRating.ID { current.value.id }
}

/// The sender's private experience of one subject across every order this store holds
/// ("your last 12 Yandex couriers averaged 4.6"): read-only, derived at read, never
/// persisted, and never a reputation — other senders' ratings live in shares this
/// device is not in (the app's Vision → "Players, trust and reputation").
public struct RatingSummary: Hashable, Sendable {
    /// Counted ratings: one per author per order.
    public var count: Int
    public var mean: Double

    public init(count: Int, mean: Double) {
        self.count = count
        self.mean = mean
    }
}

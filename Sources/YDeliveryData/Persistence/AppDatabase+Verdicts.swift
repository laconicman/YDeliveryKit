import Foundation
import GRDB

// The read side of the trust layer (the app's Collaboration → "Verdicts and
// entitlement"; Schema → "Derived integrity"): every signed row verified against
// the key row its `signingKeyID` names, the key's binding resolved through the
// authority, the signing party's entitlement judged as of the row's own stamp, and
// the projections checked against the latest verified facts. Verdicts are values
// beside the model, never fields on it (rule 5); a reader never throws on a bad
// signature and never drops a row (rule 6).

/// What one read knows about an order's parties: resolved once per call, then
/// asked per row.
struct PartyBook {
    let ownership: Ownership
    let localParty: UUID?
    let members: [Member]
    /// The membership rows that count — owner-signed.
    let memberships: [Membership]
    /// The order's key rows whose self-signature holds, by key id, with the
    /// authority's binding for each.
    let keys: [String: (key: ParticipantKey, binding: KeyBinding)]
    /// Whether the order has key rows at all: with none, a NULL signature is
    /// pre-signing history; with any, it is a write that bypassed the signing path.
    let hasKeyRows: Bool

    init(orderID: Order.ID, database: AppDatabase, authority: any IdentityAuthority) throws {
        ownership = authority.owner(of: orderID)
        localParty = authority.localParty
        members = authority.members(of: orderID)
        let rows = try database.participantKeys(orderID: orderID)
        hasKeyRows = !rows.isEmpty
        keys = rows.filter(\.selfSignatureIsValid).reduce(into: [:]) {
            $0[$1.keyID] = ($1, authority.binding(of: $1))
        }
        memberships = try database.ownerMemberships(orderID: orderID, authority: authority)
    }

    private var ownerRef: UUID? {
        switch ownership {
        case .local: localParty
        case .party(let party): party
        case .unresolved: nil
        }
    }

    /// The party's role as of a stamp, or `nil` for a party this read cannot place.
    /// The owner is the order's owner (this device on a private order). For anyone
    /// else the share's list is the trigger and the owner's signed rows are the dates
    /// (review, PR #48): a party is placed only when the list and the rows agree on
    /// their standing — in as a writer, in as a reader, or out — and then the
    /// effective row as of the stamp names the role, the list standing in before the
    /// first row; `.unknown` is a placed party with no role as of the stamp, dated past
    /// the owner's `removed` row, and reads *notEntitled*. A disagreement — a party the
    /// share no longer lists, a permission the share changed, a return the owner's
    /// device has not mirrored — is a change nobody has dated yet: nothing of theirs
    /// verifies until the owner's device writes the row, quietly, after which what they
    /// wrote while entitled stays verified and what is dated after reads *notEntitled*.
    /// No roster — the share not cached here — places nobody but the owner. The server
    /// does not deliver a row written after a removal; a row dated back into a role is
    /// the writer's claim that the server `creationDate` bound (the adoption) checks.
    func role(of party: UUID?, mine: Bool, asOf stamp: Date) -> Party.Role? {
        switch ownership {
        case .local where mine || (party != nil && party == localParty):
            return .owner
        case .party(let owner) where party == owner:
            return .owner
        default:
            break
        }
        guard let party, !members.isEmpty else { return nil }
        let listed = members.first { $0.ref == party && !$0.isOwner }
        let listedStanding = listed.map { $0.canWrite ? Membership.Role.participant : Membership.Role.reader }
        let byList: Party.Role? = listedStanding.map { .member(kind: $0) }
        let rows = memberships.filter { $0.partyRef == party }
        guard let current = Membership.effective(among: rows) else { return byList }
        guard Membership.standing(of: current.role) == listedStanding ?? Membership.Role.removed else { return nil }
        guard let effective = Membership.effective(among: rows, asOf: stamp) else { return byList }
        return effective.role == Membership.Role.removed ? .unknown : .member(kind: effective.role)
    }

    /// The verdict on one row of `table`, from its stored signing columns and the
    /// payload rebuilt from the stored row.
    func verdict(
        table: String, legRef: UUID?, stamp: Date, payload: Data,
        signingKeyID: String?, signature: String?, authorRef: UUID?
    ) -> Verdict {
        guard let signature, let signingKeyID else {
            return hasKeyRows ? .unsigned : .legacy
        }
        guard let (key, binding) = keys[signingKeyID] else { return .untrustedKey }
        guard Signatory.verify(payload: payload, signatureBase64: signature, publicKeyBase64: key.publicKey)
        else { return .invalid }
        let party: UUID?
        let mine: Bool
        switch binding {
        case .party(let bound):
            party = bound
            mine = false
        case .mine:
            party = localParty
            mine = true
        case .none:
            return .unverifiable
        case .conflict:
            return .untrustedKey
        }
        if let authorRef, let party, authorRef != party { return .invalid }
        // This device's own key is placed by definition; anyone else the read cannot
        // place is not yet verifiable.
        guard let role = role(of: party, mine: mine, asOf: stamp) ?? (mine ? .unknown : nil) else {
            return .unverifiable
        }
        let author = Party(ref: party, displayName: members.first { $0.ref == party }?.displayName, role: role)
        return Entitlement.mayWrite(role, table: table, legRef: legRef)
            ? .verified(author: author) : .notEntitled(author: author)
    }
}

extension Verdict {
    /// The party the verdict names, when it names one — a chat byline's source.
    /// Public since 0.5.5: the consumer's reads hand verdicts to views, which need
    /// the writer without switching over every case.
    public var author: Party? {
        switch self {
        case .verified(let author), .notEntitled(let author): author
        default: nil
        }
    }

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

extension AppDatabase {
    // MARK: - Attested reads

    /// The order's events with a verdict each, deduped by fact (rule 1): two devices
    /// that recorded one journal operation or one sighting wrote two rows, and rows
    /// that agree on the fact — the frozen columns minus writer identity and a
    /// sighting's provenance, the party the verdict names in place of the raw
    /// `authorRef` — collapse to one entry, the verified one when any, else the
    /// earliest stamp, then the smallest id. Rows that share a key but disagree, or
    /// whose party is not yet resolvable, stay apart, each with its own verdict.
    public func attestedEvents(orderID: Order.ID, authority: any IdentityAuthority) throws -> [Attested<OrderEvent>] {
        let book = try PartyBook(orderID: orderID, database: self, authority: authority)
        let columns = CanonicalPayload.signedColumns[OrderEventRow.tableName] ?? []
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "orderEvents" WHERE "orderID" = ? ORDER BY "at", "id"
                """, arguments: Self.args([orderID]))
        }
        let attested: [Attested<OrderEvent>] = rows.map { row in
            let event = Self.orderEvent(row)
            let payload = CanonicalPayload.payload(
                table: OrderEventRow.tableName, columns: columns,
                values: CanonicalPayload.values(from: row, columns: columns))
            let verdict = book.verdict(
                table: OrderEventRow.tableName, legRef: event.legRef, stamp: event.at, payload: payload,
                signingKeyID: row["signingKeyID"], signature: row["signature"], authorRef: event.authorRef)
            return Attested(value: event, verdict: verdict)
        }
        return Self.dedupedByFact(attested)
    }

    /// The fact an event row records, for dedupe: a journal row by its operation id,
    /// a sighting by its revision, status and digest, both with the columns that must
    /// agree; the party only when the verdict names one — an unresolvable row folds
    /// with nothing.
    private struct EventFact: Hashable {
        var orderID: UUID
        var providerEventID: Int64?
        var providerRevision: Int64?
        var providerStatus: String?
        var routeDigest: String?
        var legRef: UUID?
        var at: Date
        var kind: String
        var detail: String?
        var party: UUID?
        var unresolvable: UUID?

        init(_ attested: Attested<OrderEvent>) {
            let event = attested.value
            orderID = event.orderID
            providerEventID = event.providerEventID
            providerRevision = event.providerRevision
            providerStatus = event.providerStatus
            routeDigest = event.routeDigest
            legRef = event.legRef
            at = event.at
            kind = event.kind
            detail = event.detail
            party = attested.verdict.author?.ref
            unresolvable = attested.verdict.author == nil ? event.id : nil
        }
    }

    private static func dedupedByFact(_ events: [Attested<OrderEvent>]) -> [Attested<OrderEvent>] {
        var representatives: [EventFact: Attested<OrderEvent>] = [:]
        for candidate in events {
            let fact = EventFact(candidate)
            guard let current = representatives[fact] else {
                representatives[fact] = candidate
                continue
            }
            if preferred(candidate, over: current) { representatives[fact] = candidate }
        }
        return representatives.values.sorted {
            ($0.value.at, $0.value.id.uuidString.lowercased()) < ($1.value.at, $1.value.id.uuidString.lowercased())
        }
    }

    private static func preferred(_ a: Attested<OrderEvent>, over b: Attested<OrderEvent>) -> Bool {
        guard a.verdict.isVerified == b.verdict.isVerified else { return a.verdict.isVerified }
        guard a.value.at == b.value.at else { return a.value.at < b.value.at }
        return a.value.id.uuidString.lowercased() < b.value.id.uuidString.lowercased()
    }

    /// The order's messages with a verdict each, oldest first.
    public func attestedMessages(orderID: Order.ID, authority: any IdentityAuthority) throws -> [Attested<OrderMessage>] {
        let book = try PartyBook(orderID: orderID, database: self, authority: authority)
        let columns = CanonicalPayload.signedColumns[OrderMessageRow.tableName] ?? []
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "orderMessages" WHERE "orderID" = ? ORDER BY "sentAt", "id"
                """, arguments: Self.args([orderID]))
        }
        return rows.map { row in
            let message = Self.orderMessage(row)
            let payload = CanonicalPayload.payload(
                table: OrderMessageRow.tableName, columns: columns,
                values: CanonicalPayload.values(from: row, columns: columns))
            let verdict = book.verdict(
                table: OrderMessageRow.tableName, legRef: nil, stamp: message.sentAt, payload: payload,
                signingKeyID: row["signingKeyID"], signature: row["signature"], authorRef: message.authorRef)
            return Attested(value: message, verdict: verdict)
        }
    }

    /// One attachment with its verdict; `nil` when no such row. A blob whose hash is
    /// not the row's `dataHash` reads *invalid*: the row claims bytes it does not hold.
    public func attestedAttachment(_ id: OrderAttachment.ID, authority: any IdentityAuthority) throws -> Attested<OrderAttachment>? {
        let columns = CanonicalPayload.signedColumns[OrderAttachmentRow.tableName] ?? []
        guard let (row, blob) = try queue.read({ db -> (Row, Data?)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM "orderAttachments" WHERE "id" = ?
                """, arguments: Self.args([id])) else { return nil }
            let blob: Data? = try Row.fetchOne(db, sql: """
                SELECT "data" FROM "attachmentBlobs" WHERE "attachmentID" = ?
                """, arguments: Self.args([id]))?["data"]
            return (row, blob)
        }) else { return nil }
        let attachment = Self.orderAttachment(row)
        let book = try PartyBook(orderID: attachment.orderID, database: self, authority: authority)
        let payload = CanonicalPayload.payload(
            table: OrderAttachmentRow.tableName, columns: columns,
            values: CanonicalPayload.values(from: row, columns: columns))
        var verdict = book.verdict(
            table: OrderAttachmentRow.tableName, legRef: nil, stamp: attachment.createdAt, payload: payload,
            signingKeyID: row["signingKeyID"], signature: row["signature"], authorRef: attachment.authorRef)
        if verdict.isVerified {
            // The bytes are what the hash binds: absent, nothing is checked and the row
            // is not yet verifiable; present and different, the row claims bytes it
            // does not hold (review, PR #48).
            guard let blob else { return Attested(value: attachment, verdict: .unverifiable) }
            if let dataHash = attachment.dataHash, Self.dataHash(of: blob) != dataHash {
                verdict = .invalid
            }
        }
        return Attested(value: attachment, verdict: verdict)
    }

    static func orderAttachment(_ row: Row) -> OrderAttachment {
        OrderAttachment(
            id: row["id"], orderID: row["orderID"], kind: row["kind"], caption: row["caption"],
            byteSize: row["byteSize"], createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            authorHint: row["authorHint"], dataHash: row["dataHash"], authorRef: row["authorRef"])
    }

    // MARK: - Ratings

    /// The order's ratings with a verdict each, oldest first by `at`, then the smallest
    /// id. Every row, superseded and tampered ones included: a rating is a decision, so
    /// nothing is deduped here (rule 1); ``effectiveRatings(orderID:authority:)``
    /// selects the ones in force.
    public func attestedRatings(orderID: Order.ID, authority: any IdentityAuthority) throws -> [Attested<OrderRating>] {
        let book = try PartyBook(orderID: orderID, database: self, authority: authority)
        let columns = CanonicalPayload.signedColumns[OrderRatingRow.tableName] ?? []
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM "orderRatings" WHERE "orderID" = ? ORDER BY "at", "id"
                """, arguments: Self.args([orderID]))
        }
        return rows.map { row in
            let rating = Self.orderRating(row)
            let payload = CanonicalPayload.payload(
                table: OrderRatingRow.tableName, columns: columns,
                values: CanonicalPayload.values(from: row, columns: columns))
            let verdict = book.verdict(
                table: OrderRatingRow.tableName, legRef: rating.legRef, stamp: rating.at, payload: payload,
                signingKeyID: row["signingKeyID"], signature: row["signature"], authorRef: rating.authorRef)
            return Attested(value: rating, verdict: verdict)
        }
    }

    /// The order's ratings as they count: per (author, subject) the latest *verified*
    /// or *legacy* row with the rows it superseded, and beside them every row a warned
    /// or unplaced verdict keeps from counting (``EffectiveRatings``).
    public func effectiveRatings(orderID: Order.ID, authority: any IdentityAuthority) throws -> EffectiveRatings {
        EffectiveRatings(try attestedRatings(orderID: orderID, authority: authority))
    }

    /// The count and mean of one subject's counted ratings across every order in the
    /// store — the effective rating per author per order, never a not-counted row;
    /// `nil` when there is none. Derived at read and never persisted: this is the
    /// sender's own experience, not a reputation (``RatingSummary``).
    public func ratingSummary(
        subjectKind: String, subjectRef: String, authority: any IdentityAuthority
    ) throws -> RatingSummary? {
        let orderIDs = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT "orderID" FROM "orderRatings"
                WHERE "subjectKind" = ? AND "subjectRef" = ?
                """, arguments: Self.args([subjectKind, subjectRef])).map { $0["orderID"] as UUID }
        }
        let scores = try orderIDs.flatMap { orderID in
            try effectiveRatings(orderID: orderID, authority: authority).counted
                .map(\.current.value)
                .filter { $0.subject.kind == subjectKind && $0.subject.ref == subjectRef }
                .map(\.score)
        }
        guard !scores.isEmpty else { return nil }
        return RatingSummary(count: scores.count, mean: Double(scores.reduce(0, +)) / Double(scores.count))
    }

    // MARK: - Derived integrity

    /// The one total order over the verified rows (the app's Collaboration →
    /// "Verdicts and entitlement"): by `at`; on a tie by family — a journal row beats a
    /// claim read beats the app's own `placed`; then, within one family, the feed's
    /// own order — the higher operation id, two transitions in one second being feed
    /// order and never a coin toss (review, PR #48) — then the higher
    /// `providerRevision`; then the smallest id. `precedes` says `a` ranks below `b`.
    static func precedes(_ a: OrderEvent, _ b: OrderEvent) -> Bool {
        guard a.at == b.at else { return a.at < b.at }
        guard family(of: a) == family(of: b) else { return family(of: a) < family(of: b) }
        guard a.providerEventID == b.providerEventID else {
            return (a.providerEventID ?? .min) < (b.providerEventID ?? .min)
        }
        guard a.providerRevision == b.providerRevision else {
            return (a.providerRevision ?? .min) < (b.providerRevision ?? .min)
        }
        return a.id.uuidString.lowercased() > b.id.uuidString.lowercased()
    }

    private static func family(of event: OrderEvent) -> Int {
        if event.providerEventID != nil { return 3 }
        if event.kind == OrderEvent.Kind.sighting { return 2 }
        if event.kind == OrderEvent.Kind.placed { return 1 }
        return 0
    }

    /// The mirror's `providerStatus` against the latest verified status-bearing event.
    public func mirrorIntegrity(orderID: Order.ID, authority: any IdentityAuthority) throws -> IntegrityVerdict {
        let candidates = try attestedEvents(orderID: orderID, authority: authority)
            .filter { $0.verdict.isVerified && $0.value.providerStatus != nil }
            .map(\.value)
        guard let winner = candidates.max(by: Self.precedes), let expected = winner.providerStatus else {
            return .noSignedHistory
        }
        let stored: String? = try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT "providerStatus" FROM "orderProviderStates" WHERE "orderID" = ?
                """, arguments: Self.args([orderID]))
        }
        return stored == expected ? .consistent : .disagrees(expected: expected)
    }

    /// The stored route's digest against the latest verified digest-bearing event.
    public func routeIntegrity(orderID: Order.ID, authority: any IdentityAuthority) throws -> IntegrityVerdict {
        let candidates = try attestedEvents(orderID: orderID, authority: authority)
            .filter { $0.verdict.isVerified && $0.value.routeDigest != nil }
            .map(\.value)
        guard let winner = candidates.max(by: Self.precedes), let expected = winner.routeDigest else {
            return .noSignedHistory
        }
        let stored = try storedRouteDigest(orderID: orderID)
        return stored == expected ? .consistent : .disagrees(expected: expected)
    }

    /// The digest over the stops as stored, in position order — the read side of
    /// ``CanonicalPayload/routeDigest(for:)``.
    public func storedRouteDigest(orderID: Order.ID) throws -> String {
        let columns = CanonicalPayload.routeDigestColumns
        let quoted = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let values: [[DatabaseValue]] = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(quoted) FROM "routeStops" WHERE "orderID" = ? ORDER BY "position"
                """, arguments: Self.args([orderID])).map { CanonicalPayload.values(from: $0, columns: columns) }
        }
        return CanonicalPayload.routeDigest(stopValues: values)
    }
}

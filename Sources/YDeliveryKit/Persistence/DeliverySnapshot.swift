import Foundation

/// What an extension renders — the app's orders distilled to the fields a
/// cramped surface can show, written by the app into the shared App Group
/// container. The live database is *not* shared with extensions (the app's
/// `Schema` doc: a suspended process holding a SQLite lock is a watchdog
/// termination, and a `.complete`-protected file cannot be read from the
/// Lock Screen at all), so the widget contract is a snapshot, not a database.
///
/// The shape is a *rendering*, not a schema: it may change freely behind
/// `snapshotVersion`. Entries carry display-ready values — compact addresses,
/// the resolved order number — so a reader never re-derives app rules, and a
/// collaborator's extension never needs the private-tier definitions that
/// typed a value (YD-17).
public nonisolated struct DeliverySnapshot: Codable, Sendable {
    /// Bump when a field's *meaning* changes; additive fields decode on old
    /// readers without one.
    public static let currentVersion = 1

    public var snapshotVersion: Int
    /// When the app rendered this — the reader's own freshness word («as of»).
    public var renderedAt: Date
    /// Recent-first, capped by the renderer — live orders and the repeat
    /// window the working widget offers, not history at scale.
    public var orders: [Entry]

    public init(renderedAt: Date, orders: [Entry],
                snapshotVersion: Int = DeliverySnapshot.currentVersion) {
        self.snapshotVersion = snapshotVersion
        self.renderedAt = renderedAt
        self.orders = orders
    }

    public nonisolated struct Entry: Codable, Sendable, Identifiable {
        public var id: UUID
        public var status: OrderStatus
        /// The waiting widget's membership — a claim exists and the story
        /// isn't over — resolved by the renderer, not re-derived here.
        public var isLive: Bool
        /// The sender's own «№4417», resolved at render — the extension has
        /// no definitions tier to join against.
        public var orderNumber: String?
        /// Compact forms — the surfaces only ever show the shed-city shape.
        public var pickupAddress: String?
        public var destinationAddress: String?
        /// The repeat dedup basis — full address + door + metre, opaque to
        /// the reader (`RoutePoint.destinationKey`).
        public var destinationKey: String?
        public var courierName: String?
        public var courierVehicle: String?
        /// The wire's own status word — `ProviderStatusPhrase` translates it.
        public var providerStatus: String?
        public var etaAt: Date?
        public var providerObservedAt: Date?

        public init(id: UUID, status: OrderStatus, isLive: Bool,
                    orderNumber: String? = nil,
                    pickupAddress: String? = nil,
                    destinationAddress: String? = nil,
                    destinationKey: String? = nil,
                    courierName: String? = nil,
                    courierVehicle: String? = nil,
                    providerStatus: String? = nil,
                    etaAt: Date? = nil,
                    providerObservedAt: Date? = nil) {
            self.id = id
            self.status = status
            self.isLive = isLive
            self.orderNumber = orderNumber
            self.pickupAddress = pickupAddress
            self.destinationAddress = destinationAddress
            self.destinationKey = destinationKey
            self.courierName = courierName
            self.courierVehicle = courierVehicle
            self.providerStatus = providerStatus
            self.etaAt = etaAt
            self.providerObservedAt = providerObservedAt
        }
    }
}

public nonisolated extension DeliverySnapshot.Entry {
    /// The render the app performs on material change. `isLive` is decided
    /// here — a live order is a provider-tracked one whose story isn't over —
    /// so the extension's membership check is a stored fact, not a second copy
    /// of the rule.
    init(order: Order, orderNumber: String?) {
        self.init(
            id: order.id,
            status: order.status,
            isLive: order.claimID != nil
                && [.searching, .active, .attention].contains(order.status),
            orderNumber: orderNumber,
            pickupAddress: order.route.first?.compactAddress,
            destinationAddress: order.route.last?.compactAddress,
            destinationKey: order.route.last?.destinationKey,
            courierName: order.courierName,
            courierVehicle: order.courierVehicle,
            providerStatus: order.providerStatus,
            etaAt: order.etaAt,
            providerObservedAt: order.providerObservedAt)
    }
}

/// The file half of the widget contract — `deliveries-snapshot.json` at the
/// App Group root. Unlike the substrate stores this file rescues nothing:
/// a snapshot is rebuildable from the database, so malformed bytes read as
/// *absent* (the extension's empty state) rather than earning a sidecar.
/// Writes are atomic — a reader mid-render sees the last complete file or
/// the new one, never a torn half.
public nonisolated enum DeliverySnapshotStore {
    public static let filename = "deliveries-snapshot.json"

    /// The extension's read. `nil` covers every unreadable case — no group,
    /// no file, torn write, a shape this reader's version predates — because
    /// the surfaces render *empty*, never crash.
    public static func read(inAppGroup id: String,
                            fileManager: FileManager = .default) -> DeliverySnapshot? {
        guard let url = url(inAppGroup: id, fileManager: fileManager),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeliverySnapshot.self, from: data)
    }

    /// The app's render. `.completeUntilFirstUserAuthentication` is the whole
    /// point of the file: an accessory widget renders on a locked device, and
    /// the default-for-the-app protection class may be stricter than that
    /// allows. Throws — a failed write leaves the last good snapshot in
    /// place, and the caller logs rather than strands a timeline.
    public static func write(_ snapshot: DeliverySnapshot, inAppGroup id: String,
                             fileManager: FileManager = .default) throws {
        guard let url = url(inAppGroup: id, fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    private static func url(inAppGroup id: String,
                            fileManager: FileManager) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent(filename)
    }
}

import CryptoKit
import Foundation
import GRDB
import Security
import Testing
import os
import YDeliveryKit
@testable import YDeliveryData

/// The trust layer's primitives (the app's Collaboration → "Keys", "The canonical
/// payload"): what we sign with, the bytes a signature covers, and the custody that
/// hands the store its key. No writer signs yet; the contract is pinned here so the
/// signed facts can rely on it. The Secure Enclave path of `DeviceKeyStore` is
/// device-verified only — the simulator has no enclave and the test host no keychain
/// access group — so these tests cover the software custody and say so.
@Suite("Signing primitives")
struct SigningPrimitivesTests {
    private let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SigningPrimitivesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeDatabase(keyStore: any SigningKeyStore = EphemeralKeyStore()) -> AppDatabase {
        AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed",
            containerIdentifier: "iCloud.test", keyStore: keyStore)
    }

    // MARK: Signatory

    @Test("A software key signs 64 raw bytes that verify under its X9.63 key and under no other")
    func softwareRoundTrip() throws {
        let key = Signatory.ephemeral()
        let payload = Data("the bound values".utf8)
        let signature = try key.sign(payload)
        #expect(signature.count == 64, "raw r ‖ s, never DER")
        let encoded = try key.signatureBase64(for: payload)
        #expect(Signatory.verify(payload: payload, signatureBase64: encoded, publicKeyBase64: key.publicKeyBase64))
        #expect(!Signatory.verify(payload: payload + [0], signatureBase64: encoded,
                                  publicKeyBase64: key.publicKeyBase64), "a changed payload fails")
        #expect(!Signatory.verify(payload: payload, signatureBase64: encoded,
                                  publicKeyBase64: Signatory.ephemeral().publicKeyBase64), "a foreign key fails")
        #expect(!Signatory.verify(payload: payload, signatureBase64: "not base64!", publicKeyBase64: key.publicKeyBase64),
                "a decode failure is not verified, never a crash")
        #expect(!Signatory.verify(payload: payload, signatureBase64: encoded, publicKeyBase64: "AAAA"),
                "a key that is not an X9.63 point is not verified")
        #expect(key.custody == .software)
    }

    @Test("A key id names the algorithm and the payload version, then eight bytes of the key's hash")
    func keyIDShape() {
        let key = Signatory.ephemeral()
        #expect(key.keyID.hasPrefix(Signatory.keyIDPrefix))
        #expect(key.keyID.count == Signatory.keyIDPrefix.count + 16)
        #expect(key.keyID == Signatory.keyID(publicKeyX963: key.publicKeyX963),
                "the read side recomputes it from the published key")
        #expect(key.keyID != Signatory.ephemeral().keyID)
    }

    @Test("The published key is the 65-byte X9.63 point and rebuilds the same public key")
    func publicKeyX963RoundTrips() throws {
        let key = Signatory.ephemeral()
        #expect(key.publicKeyX963.count == 65)
        let rebuilt = try P256.Signing.PublicKey(x963Representation: key.publicKeyX963)
        #expect(rebuilt.rawRepresentation == key.publicKey.rawRepresentation)
    }

    // MARK: Canonical payload

    /// The published vector: a verifier on any platform must produce these bytes
    /// for these values. Computed independently (Python `struct`) before the Swift
    /// existed: `YDX2 ‖ "vector" 0x00 ‖ n 0x00 NULL ‖ t 0x00 TEXT(7, "é—ю") ‖
    /// i 0x00 INTEGER(42) ‖ r 0x00 REAL(1.5) ‖ b 0x00 BLOB(3, 01 02 ff)`.
    @Test("The canonical payload matches the published vector byte for byte")
    func payloadVector() {
        let payload = CanonicalPayload.payload(
            table: "vector", columns: ["n", "t", "i", "r", "b"],
            values: [.null, "é—ю".databaseValue, 42.databaseValue, 1.5.databaseValue,
                     Data([1, 2, 255]).databaseValue])
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "59445832766563746f72006e000074000100000007c3a9e28094d18e690002000000000000002a7200033ff8000000000000620004000000030102ff")
        #expect(payload.count == 60)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "989f08f4a81254182fd037f944bb727ec9823dbaa68aac801945f8950cca68a4")
    }

    @Test("The payload is sensitive to column order, to the table name and to the version")
    func payloadIsOrderSensitive() {
        let values: [DatabaseValue] = ["a".databaseValue, "b".databaseValue]
        let one = CanonicalPayload.payload(table: "t", columns: ["x", "y"], values: values)
        #expect(one != CanonicalPayload.payload(table: "t", columns: ["y", "x"], values: values))
        #expect(one != CanonicalPayload.payload(table: "u", columns: ["x", "y"], values: values))
        #expect(one.prefix(4) == Data(CanonicalPayload.version.utf8))
        #expect(CanonicalPayload.signedColumns["orderEvents"]?.contains("signature") == false,
                "a row's signature never signs itself")
        for columns in CanonicalPayload.signedColumns.values {
            #expect(!columns.contains("signingKeyID") && !columns.contains("signature"))
        }
    }

    @Test("Values bound through args read back as the same database values, for every tag")
    func boundValuesReadBackIdentically() throws {
        let database = makeDatabase()
        let uuid = UUID()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000.5)
        let bindings: [(any DatabaseValueConvertible)?] = [
            nil, "é—ю", 42, 1.5, Data([1, 2, 255]), uuid, stamp.timeIntervalSince1970, true, Int64.max,
        ]
        let columns = ["n", "t", "i", "r", "b", "u", "d", "f", "big"]
        let stored: [DatabaseValue] = try database.queue.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE "vector" ("n", "t", "i", "r", "b", "u", "d", "f", "big")
                """)
            try db.execute(sql: """
                INSERT INTO "vector" VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: AppDatabase.args(bindings))
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM "vector"
                """)!
            return CanonicalPayload.values(from: row, columns: columns)
        }
        let bound = CanonicalPayload.databaseValues(bindings)
        #expect(bound == stored, "the writer's bytes and the reader's bytes are one payload")
        #expect(bound[5] == uuid.uuidString.lowercased().databaseValue, "UUIDs bind lowercase TEXT")
        #expect(bound[7] == 1.databaseValue, "a Bool is INTEGER 1")
        #expect(CanonicalPayload.payload(table: "vector", columns: columns, values: bound)
                == CanonicalPayload.payload(table: "vector", columns: columns, values: stored))
    }

    // MARK: Route digest

    private func stop(_ address: String, building: String? = nil, visited: Bool = false,
                      role: RoutePoint.Role? = nil) -> RoutePoint {
        RoutePoint(
            latitude: 55.75, longitude: 37.61, address: address,
            addressParts: building.map {
                AddressParts(building: $0, entrance: "2", floor: "3", apartment: "4", intercom: "5") },
            contactName: "Иван Петров", contactGivenName: "Иван", contactFamilyName: "Петров",
            contactPhone: "+79990000001", contactPhoneExtension: nil,
            visit: visited ? RoutePoint.Visit(status: .visited, visitedAt: .now) : nil,
            role: role)
    }

    @Test("The route digest covers the sender's columns only, in position order")
    func routeDigestCoversSenderColumnsOnly() {
        let route = [stop("Тверская, 6", building: "к. 1"), stop("Арбат, 1")]
        let digest = CanonicalPayload.routeDigest(for: route)
        #expect(digest.count == 64, "hex SHA-256")
        #expect(CanonicalPayload.routeDigest(for: [stop("Тверская, 6", building: "к. 1", visited: true),
                                                   stop("Арбат, 1", visited: true)]) == digest,
                "visit columns are provider truth and excluded")
        #expect(CanonicalPayload.routeDigest(for: [stop("Тверская, 6", building: "к. 1", role: .pickup),
                                                   stop("Арбат, 1", role: .dropoff)]) == digest,
                "an absent role binds the index's word, as the insert always has")
        #expect(CanonicalPayload.routeDigest(for: [stop("Тверская, 7", building: "к. 1"), stop("Арбат, 1")]) != digest,
                "an address change is a different route")
        #expect(CanonicalPayload.routeDigest(for: [stop("Тверская, 6", building: "к. 2"), stop("Арбат, 1")]) != digest,
                "a building change is a different route")
        #expect(CanonicalPayload.routeDigest(for: [stop("Арбат, 1"), stop("Тверская, 6", building: "к. 1")]) != digest,
                "position is content")
    }

    @Test("The digest over the model equals the digest over the stored stops")
    func routeDigestMatchesStoredStops() throws {
        let database = makeDatabase()
        let order = Order(
            created: .now, status: .active,
            route: [stop("Тверская, 6", building: "к. 1", visited: true), stop("Арбат, 1")],
            claimID: "claim-digest")
        try database.recordOrder(order, providerObservedAt: .now)
        let stored: [[DatabaseValue]] = try database.queue.read { db in
            let quoted = CanonicalPayload.routeDigestColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            return try Row.fetchAll(db, sql: """
                SELECT \(quoted) FROM "routeStops" WHERE "orderID" = ? ORDER BY "position"
                """, arguments: AppDatabase.args([order.id])).map {
                    CanonicalPayload.values(from: $0, columns: CanonicalPayload.routeDigestColumns)
                }
        }
        #expect(stored.count == 2)
        #expect(CanonicalPayload.routeDigest(stopValues: stored) == CanonicalPayload.routeDigest(for: order.route),
                "same bytes by construction: the insert binds the digest's own list")
    }

    // MARK: Custody

    /// A store that fails a configurable number of times before yielding one key —
    /// the transient Keychain failure the cache must not remember.
    final class FlakyKeyStore: SigningKeyStore, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<(failuresLeft: Int, calls: Int)>(initialState: (1, 0))
        private let key = Signatory.ephemeral()
        var calls: Int { state.withLock { $0.calls } }

        func signatory() throws -> Signatory {
            try state.withLock { state in
                state.calls += 1
                guard state.failuresLeft == 0 else {
                    state.failuresLeft -= 1
                    throw KeyCustodyError(operation: .read, status: errSecInteractionNotAllowed)
                }
                return key
            }
        }
    }

    @Test("The store caches only a resolved key: a failure leaves the cell empty and is asked again")
    func cacheHoldsOnlySuccess() throws {
        let flaky = FlakyKeyStore()
        let database = makeDatabase(keyStore: flaky)
        #expect(throws: KeyCustodyError.self) { try database.signatory() }
        let first = try database.signatory()
        let second = try database.signatory()
        #expect(first.keyID == second.keyID)
        #expect(flaky.calls == 2, "two asks: the failure and the success; the cache answered the third")
    }

    @Test("The ephemeral store is the default and signs on every open")
    func ephemeralIsTheDefault() throws {
        let database = AppDatabase(
            directory: directory, providerAccountRef: "test:unattributed", containerIdentifier: "iCloud.test")
        let key = try database.signatory()
        #expect(key.custody == .software)
        #expect(try database.signatory().keyID == key.keyID)
    }

    /// Whether this host may touch the keychain at all: a generic xctest host in the
    /// simulator carries no application identifier, so every `SecItem` call answers
    /// `errSecMissingEntitlement` (-34018) and the device store's round trip is
    /// device-verified only, as the header says. A host that can reach its keychain
    /// — a device, or an app-hosted test target — runs it.
    static let keychainIsReachable: Bool = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "YDeliveryKit.keychain-probe",
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) != errSecMissingEntitlement
    }()

    /// The simulator has no Secure Enclave, so a reachable keychain exercises the
    /// software custody and leaves the keychain as it found it; the enclave path is
    /// verified on a device.
    @Test("The device key store creates one key, returns it again, and forgets it on request",
          .enabled(if: SigningPrimitivesTests.keychainIsReachable,
                   "this host cannot reach a keychain (errSecMissingEntitlement); device-verified only"))
    func deviceKeyStoreRoundTripsInSoftwareCustody() throws {
        let store = DeviceKeyStore(accessGroup: nil)
        try store.forget()
        defer { try? store.forget() }
        let first = try store.signatory()
        #expect(first.custody == (SecureEnclave.isAvailable ? .enclave : .software))
        let again = try store.signatory()
        #expect(again.keyID == first.keyID, "the item is read back, not minted again")
        let payload = Data("round trip".utf8)
        #expect(Signatory.verify(payload: payload, signatureBase64: try again.signatureBase64(for: payload),
                                 publicKeyBase64: first.publicKeyBase64))
        try store.forget()
        #expect(try store.signatory().keyID != first.keyID, "a forgotten key is a new key")
    }

    // MARK: Verdicts

    @Test("Warned verdicts carry a sentence; quiet ones carry none")
    func verdictWarnings() {
        let owner = Party(ref: UUID(), role: .owner)
        #expect(Verdict.verified(author: owner).warning == nil)
        #expect(Verdict.legacy.warning == nil)
        #expect(Verdict.unverifiable.warning == nil)
        for warned in [Verdict.unsigned, .invalid, .untrustedKey, .notEntitled(author: owner)] {
            #expect(warned.isWarned, "\(warned)")
        }
    }
}

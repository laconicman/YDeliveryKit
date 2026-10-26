import CryptoKit
import Foundation
import OSLog
import Security

/// Custody for the device's signing key (the app's Collaboration → "Keys"). One
/// keypair per device, created on first need and never exported or synchronised;
/// the consumer picks the custody by how it builds the store — the App Group store
/// gets ``DeviceKeyStore``, a throwaway directory gets ``EphemeralKeyStore`` — so
/// signing is never "off", only sometimes unpersisted.
public protocol SigningKeyStore: Sendable {
    /// The device's key, created on first need. Throws when custody cannot be
    /// reached *this time*; the store caches only a resolved key and asks again on
    /// the next write, so a transient failure costs one unsigned row, never the
    /// process lifetime.
    func signatory() throws -> Signatory
}

/// A Keychain or CryptoKit failure on the way to the device key, named by the
/// operation and the `OSStatus` it ended with.
public struct KeyCustodyError: LocalizedError, Hashable, Sendable {
    public enum Operation: String, Sendable {
        case read
        case add
        case reread = "re-read"
        case rehydrate
        case accessControl = "access control"
    }

    public let operation: Operation
    public let status: OSStatus

    public var errorDescription: String? {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "no description"
        return "The device signing key could not be \(operation.rawValue): OSStatus \(status), \(message)."
    }
}

/// An in-memory software keypair for previews, tests and any store built without
/// an access group. Its rows read as "mine" on this device and "not yet verifiable"
/// anywhere else, which is correct for fixtures that never sync.
public struct EphemeralKeyStore: SigningKeyStore {
    private let key: Signatory

    public init() {
        key = .ephemeral()
    }

    public func signatory() throws -> Signatory { key }
}

/// The device key as a generic-password Keychain item in the consumer's App Group
/// access group (so it survives an app transfer with the group), accessible after
/// first unlock on this device only — background sync signs, so no biometric gate —
/// and `kSecAttrSynchronizable` stated false: a synchronised item is what let two
/// offline devices mint two keys under one account in the parked design. Where the
/// Secure Enclave is available the item holds an enclave key's `dataRepresentation`,
/// an opaque blob only this device can use; elsewhere a software key's raw bytes.
/// The item's label records which, so the key is rehydrated the way it was made.
struct DeviceKeyStore: SigningKeyStore {
    /// The App Group the consumer names (Kit rule 2); `nil` only in a host without
    /// a keychain access group, such as a test runner. An App Group identifier is a
    /// keychain access group on its own — no `keychain-access-groups` entry is needed
    /// (Apple, "Sharing access to keychain items among a collection of apps") — and
    /// the consuming app already keeps its OAuth token under the same group.
    let accessGroup: String?

    static let service = "YDeliveryKit.device-signing-key"
    static let account = "device-signing-key"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "YDelivery", category: "signing")
    /// Each distinct status is logged once per process — a Keychain that refuses
    /// refuses every write, and one line says so.
    private static let reported = OSAllocatedUnfairLock<Set<OSStatus>>(initialState: [])

    init(accessGroup: String?) {
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Get-or-create. `errSecDuplicateItem` means another writer in this process
    /// won the creation race: re-read whoever won, because two keys under one item
    /// is the divergence this exists to prevent.
    func signatory() throws -> Signatory {
        if let stored = try read() {
            return try rehydrate(stored)
        }
        let made = try make()
        var attributes = query
        attributes[kSecAttrLabel as String] = made.custody.rawValue
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = made.data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return made.signatory
        case errSecDuplicateItem:
            guard let stored = try read() else {
                throw report(KeyCustodyError(operation: .reread, status: errSecItemNotFound))
            }
            return try rehydrate(stored)
        default:
            throw report(KeyCustodyError(operation: .add, status: status))
        }
    }

    /// Deletes the item — a reset, and the tests' way to leave the host's keychain
    /// as they found it. A key forgotten here is a new key at the next write; old
    /// signatures stay valid under the old key row.
    func forget() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw report(KeyCustodyError(operation: .read, status: status))
        }
    }

    private func read() throws -> (custody: Signatory.Custody, data: Data)? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let item = result as? [String: Any],
                  let data = item[kSecValueData as String] as? Data,
                  let label = item[kSecAttrLabel as String] as? String,
                  let custody = Signatory.Custody(rawValue: label)
            else { throw report(KeyCustodyError(operation: .read, status: errSecDecode)) }
            return (custody, data)
        case errSecItemNotFound:
            return nil
        default:
            throw report(KeyCustodyError(operation: .read, status: status))
        }
    }

    private func make() throws -> (signatory: Signatory, custody: Signatory.Custody, data: Data) {
        guard SecureEnclave.isAvailable else {
            let key = P256.Signing.PrivateKey()
            return (.software(key), .software, key.rawRepresentation)
        }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)
        else { throw report(KeyCustodyError(operation: .accessControl, status: errSecParam)) }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        return (.enclave(key), .enclave, key.dataRepresentation)
    }

    private func rehydrate(_ stored: (custody: Signatory.Custody, data: Data)) throws -> Signatory {
        do {
            switch stored.custody {
            case .enclave:
                return .enclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.data))
            case .software:
                return .software(try P256.Signing.PrivateKey(rawRepresentation: stored.data))
            }
        } catch {
            throw report(KeyCustodyError(operation: .rehydrate, status: errSecDecode))
        }
    }

    private func report(_ error: KeyCustodyError) -> KeyCustodyError {
        let first = Self.reported.withLock { $0.insert(error.status).inserted }
        if first {
            Self.logger.error("\(error.errorDescription ?? "device signing key failure", privacy: .public)")
        }
        return error
    }
}

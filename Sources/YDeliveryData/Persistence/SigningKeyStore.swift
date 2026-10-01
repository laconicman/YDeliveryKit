import Foundation
import OSLog
import Security

/// Custody for the record-signing keypair (doc:Collaboration → "Provider state is
/// signed by the device that wrote it"). `kSecClassGenericPassword`, accessible
/// after first unlock, and — the deliberate difference from the OAuth token —
/// `kSecAttrSynchronizable`: the signing key must exist on every device the
/// owner writes from, so it rides iCloud Keychain. The token does not because it
/// spends money; this key only attests authorship, and a share participant can
/// never hold it because they never share the owner's keychain.
///
/// Both names are the consumer's (Kit rule 2): `service` distinguishes this item
/// from the app's other credentials, `accessGroup` is the App Group the consumer
/// already uses for keychain items — the prefix-free group survives an app
/// transfer where the team-prefixed default would strand the key.
///
/// Every failure reads as `nil`, never a throw: a device that cannot reach its
/// key writes unsigned rows — which readers then flag honestly — rather than
/// losing the write (the substrate's render-don't-refuse rule).
struct SigningKeyStore: Sendable {
    var service: String
    var accessGroup: String?

    private var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "owner-signing-key",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// The stored key, creating and synchronizing one on first need. Creation is
    /// a get-or-create race: two devices (or a repeat after a duplicate write)
    /// both end on whichever item won — the loser re-reads, because two
    /// different private keys on one account is the divergence this exists to
    /// prevent.
    func signatory() -> Signatory? {
        if let data = read() {
            return try? Signatory(rawRepresentation: data)
        }
        let generated = Signatory()
        var attributes = query
        attributes[kSecValueData as String] = generated.privateKeyData
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = true

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return generated
        case errSecDuplicateItem:
            // Lost the creation race — re-read whoever won. A second miss means
            // the item vanished between calls: report no key, write unsigned.
            return read().flatMap { try? Signatory(rawRepresentation: $0) }
        default:
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "YDelivery",
                   category: "persistence")
                .error("Signing key store write failed: \(status)")
            return nil
        }
    }

    private func read() -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(attributes as CFDictionary, &result)
                == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }
}

import CryptoKit
import Foundation

/// One device's signing key, in one of two custodies (the app's Collaboration →
/// "Keys — what we sign with, custody, publication, trust"): ECDSA over P-256 with
/// SHA-256, because the Secure Enclave signs P-256 and nothing else, and a server
/// verifies the same bytes unchanged with swift-crypto. A key never leaves its
/// device and is never synchronised; each of the owner's devices holds one, and
/// every device's key is valid on its own once published as a `participantKeys`
/// row (the trust layer's rule 4).
///
/// Signatures are the 64-byte raw `r ‖ s` form, carried base64 in TEXT columns;
/// public keys are the 65-byte X9.63 uncompressed point, so any verifier on any
/// platform reconstructs them without a vendor format.
public enum Signatory: Sendable {
    /// A key generated inside the Secure Enclave; its private half never exists
    /// outside the hardware, and `dataRepresentation` is an opaque blob only this
    /// device can use.
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    /// A software key — the simulator, test hosts, hardware without an enclave, and
    /// the ephemeral key previews and tests sign with.
    case software(P256.Signing.PrivateKey)

    /// The algorithm and the payload version a key id names, legible from the
    /// column alone: a future algorithm is a new prefix, not a migration.
    public static let keyIDPrefix = "p256.v2."

    /// A fresh software keypair that lives only in memory.
    public static func ephemeral() -> Signatory {
        .software(P256.Signing.PrivateKey())
    }

    /// Which custody holds the key — what the Keychain item records so the key is
    /// rehydrated the way it was made.
    public enum Custody: String, Sendable {
        case enclave
        case software
    }

    public var custody: Custody {
        switch self {
        case .enclave: .enclave
        case .software: .software
        }
    }

    public var publicKey: P256.Signing.PublicKey {
        switch self {
        case .enclave(let key): key.publicKey
        case .software(let key): key.publicKey
        }
    }

    /// The 65-byte X9.63 uncompressed point — what a `participantKeys.publicKey`
    /// column carries, base64.
    public var publicKeyX963: Data { publicKey.x963Representation }

    public var publicKeyBase64: String { publicKeyX963.base64EncodedString() }

    /// `p256.v2.` followed by the first eight bytes of SHA-256 over the X9.63 key, hex.
    public var keyID: String { Self.keyID(publicKeyX963: publicKeyX963) }

    /// The key id a published public key must carry — the read side recomputes it
    /// and a row whose `keyID` disagrees with its `publicKey` is a rewritten row.
    public static func keyID(publicKeyX963: Data) -> String {
        keyIDPrefix + SHA256.hash(data: publicKeyX963).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The raw 64-byte `r ‖ s` signature over `payload` (SHA-256 inside).
    public func sign(_ payload: Data) throws -> Data {
        switch self {
        case .enclave(let key): try key.signature(for: payload).rawRepresentation
        case .software(let key): try key.signature(for: payload).rawRepresentation
        }
    }

    /// `sign(_:)`, base64 — the TEXT a signature column stores.
    public func signatureBase64(for payload: Data) throws -> String {
        try sign(payload).base64EncodedString()
    }

    /// Verifies a stored signature over a payload under a published key, with no
    /// custody involved. Every decode failure — bad base64, a key that is not an
    /// X9.63 point, a signature that is not 64 bytes — is simply *not verified*:
    /// the caller renders the verdict, it does not crash or discard the row.
    public static func verify(
        payload: Data, signatureBase64: String, publicKeyBase64: String
    ) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let signatureData = Data(base64Encoded: signatureBase64),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        else { return false }
        return key.isValidSignature(signature, for: payload)
    }
}

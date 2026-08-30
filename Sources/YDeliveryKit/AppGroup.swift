/// The one App Group this app and its future extension targets share. The identifier
/// serves two jobs: it names the group *container* the order store lives in, and it names
/// the keychain *access group* the OAuth token lives in.
///
/// The second job is deliberate transfer-proofing (Design → "Surviving an account
/// transfer"): default keychain access groups are prefixed with the Team ID, so an app
/// transfer to another developer account strands every stored credential (QA1726/TN2311).
/// App Group identifiers carry no team prefix and re-register to the recipient account,
/// so items stored under this group survive the transfer.
public nonisolated enum AppGroup {
    /// The suffix matches the app's bundle identifier.
    public static let id = "group.com.learnable.YDelivery"
}

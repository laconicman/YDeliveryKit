import Foundation

extension LocalizedStringResource.BundleDescription {
    /// The data half's own bundle — `LocalizedStringResource` cannot take `Bundle`
    /// directly, only a description of where to find it. Resolves
    /// `YDeliveryKit_YDeliveryData.bundle`, the catalog this target ships; the UI
    /// half's sibling is ``.kit``. Shared by every string the data target owns —
    /// `ProviderStatusPhrase`, `RoutePoint.contactSummary`, `AppDatabase.ShareError` —
    /// so they read identically in app, widget, and notification.
    public static let data = atURL(Bundle.data.bundleURL)
}

private final class DataBundleAnchor {}

extension Bundle {
    /// `Bundle.module` for `nonisolated` readers: toolchains before Xcode 26.5 emit
    /// the generated accessor MainActor-isolated, and a `nonisolated` context —
    /// including a `static let` initializer — cannot read it at all. Re-derived with
    /// the same candidate search order, over Foundation API that is nonisolated on
    /// every toolchain. The anchor lives in this module, so `Bundle(for:)` names the
    /// right neighbour in every packaging style — no cross-target sweep (the one
    /// `Bundle.kit` needed, having anchored here while resolving the UI bundle).
    static let data: Bundle = {
        let bundleName = "YDeliveryKit_YDeliveryData"
        let overrides: [URL]
        #if DEBUG
        // PACKAGE_RESOURCE_BUNDLE_* redirect the lookup in package test hosts — kept
        // in step with the generated accessor so test-bundle loads resolve the same.
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
                       ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            overrides = [URL(fileURLWithPath: override)]
        } else {
            overrides = []
        }
        #else
        overrides = []
        #endif
        // The generated accessor's own order: the host app, the module's own
        // bundle (framework packaging puts the resource bundle inside it), the
        // host again for command-line tools — plus the anchor's Resources dir,
        // the spelling this file has always used and test hosts rely on.
        for candidate in overrides + [Bundle.main.resourceURL,
                                      Bundle(for: DataBundleAnchor.self).bundleURL,
                                      Bundle.main.bundleURL,
                                      Bundle(for: DataBundleAnchor.self).resourceURL] {
            if let url = candidate?.appendingPathComponent("\(bundleName).bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        fatalError("unable to find bundle named \(bundleName)")
    }()
}

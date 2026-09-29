import Foundation

private final class KitBundleAnchor {}

extension Bundle {
    /// `Bundle.module` spelled nonisolated: toolchains before Xcode 26.5 emit the
    /// generated accessor MainActor-isolated, which nonisolated readers here —
    /// `StatusTimeline.entries` is one — cannot touch. Re-derived with the
    /// generated accessor's own candidate order, over Foundation API that is
    /// nonisolated on every toolchain. Public since 0.3.11, when the helper lived
    /// in the data target; the anchor is in this module now, so the lookup needs
    /// no cross-bundle sweep.
    nonisolated public static var kit: Bundle {
        let bundleName = "YDeliveryKit_YDeliveryKit"
        let overrides: [URL]
        #if DEBUG
        // PACKAGE_RESOURCE_BUNDLE_* redirect the lookup in package test hosts —
        // kept in step with the generated accessor.
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
                       ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            overrides = [URL(fileURLWithPath: override)]
        } else {
            overrides = []
        }
        #else
        overrides = []
        #endif
        for candidate in overrides + [Bundle.main.resourceURL,
                                      Bundle(for: KitBundleAnchor.self).bundleURL,
                                      Bundle.main.bundleURL,
                                      Bundle(for: KitBundleAnchor.self).resourceURL] {
            if let url = candidate?.appendingPathComponent("\(bundleName).bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        fatalError("unable to find bundle named \(bundleName)")
    }
}

extension LocalizedStringResource.BundleDescription {
    /// The UI half's own bundle — `StatusChip`, `PointBadge`, `ETALabel`,
    /// `OrderIdentity`, `StatusTimeline` resolve their words here. The data
    /// half's sibling is ``.data``.
    nonisolated public static var kit: Self { atURL(Bundle.kit.bundleURL) }
}

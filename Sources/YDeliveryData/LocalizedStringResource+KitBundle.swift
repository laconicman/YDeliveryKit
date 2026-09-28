import Foundation

extension LocalizedStringResource.BundleDescription {
    /// The package's own bundle — `LocalizedStringResource` cannot take `Bundle.module`
    /// directly, only a description of where to find it. Shared by every component whose
    /// words must read identically in app, widget, and notification.
    public static let kit = atURL(Bundle.kit.bundleURL)
}

private final class KitBundleAnchor {}

extension Bundle {
    /// `Bundle.module` for `nonisolated` readers: toolchains before Xcode 26.5 emit
    /// the generated accessor MainActor-isolated, and a `nonisolated` context —
    /// including a `static let` initializer — cannot read it at all. Re-derived with
    /// the same candidate search order, over Foundation API that is nonisolated on
    /// every toolchain.
    public static let kit: Bundle = {
        let bundleName = "YDeliveryKit_YDeliveryKit"
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
        for candidate in overrides + [Bundle.main.resourceURL,
                                      Bundle(for: KitBundleAnchor.self).resourceURL,
                                      Bundle.main.bundleURL] {
            if let url = candidate?.appendingPathComponent("\(bundleName).bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        // Framework-packaged hosts keep the resource bundle beside *YDeliveryKit*,
        // a module this file cannot anchor to — the anchor lives here, in the data
        // target, and its bundle is the wrong neighbour. Sweep every loaded bundle
        // and framework for a nested copy before giving up.
        for bundle in Bundle.allBundles + Bundle.allFrameworks where bundle != Bundle.main {
            if let url = bundle.url(forResource: bundleName, withExtension: "bundle"),
               let found = Bundle(url: url) {
                return found
            }
        }
        fatalError("unable to find bundle named \(bundleName)")
    }()
}

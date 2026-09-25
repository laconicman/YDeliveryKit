import Foundation

extension LocalizedStringResource.BundleDescription {
    /// The package's own bundle — `LocalizedStringResource` cannot take `Bundle.module`
    /// directly, only a description of where to find it. Shared by every component whose
    /// words must read identically in app, widget, and notification.
    nonisolated static let kit = atURL(Bundle.kit.bundleURL)
}

extension Bundle {
    /// `Bundle.module` for `nonisolated` readers: toolchains before Xcode 26.5 emit
    /// the generated accessor MainActor-isolated, which a `nonisolated` context cannot
    /// read inline — a `static let` initializer is exempt, so the indirection lives
    /// here instead of at each call site.
    nonisolated static let kit: Bundle = .module
}

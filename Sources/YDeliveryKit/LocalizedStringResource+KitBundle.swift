import Foundation

extension LocalizedStringResource.BundleDescription {
    /// The package's own bundle — `LocalizedStringResource` cannot take `Bundle.module`
    /// directly, only a description of where to find it. Shared by every component whose
    /// words must read identically in app, widget, and notification.
    nonisolated static let kit = atURL(Bundle.module.bundleURL)
}

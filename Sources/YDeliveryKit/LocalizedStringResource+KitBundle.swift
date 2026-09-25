import Foundation

extension LocalizedStringResource.BundleDescription {
    /// The package's own bundle — `LocalizedStringResource` cannot take `Bundle.module`
    /// directly, only a description of where to find it. Shared by every component whose
    /// words must read identically in app, widget, and notification — and reachable
    /// from `nonisolated` contexts on toolchains whose generated `.module` accessor
    /// predates `nonisolated` (Xcode < 26.5), because a description is a Sendable
    /// value, not the isolated `Bundle` itself.
    nonisolated static let kit = atURL(Bundle.module.bundleURL)
}

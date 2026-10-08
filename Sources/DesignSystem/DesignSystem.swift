import Foundation

/// DesignSystem owns the theme protocol, the semantic tokens, and the skinned
/// components the app screens are assembled from.
///
/// Hard rules for this module — see Themes/README.md:
///
/// - No `import AudioCore`. Components take plain data and callbacks; they
///   know nothing about taps, buffers, or biquads.
/// - No color, font, corner radius, spacing value, or icon name appears as a
///   literal anywhere except under `Themes/`. Enforced at build time.
public enum DesignSystem {
    /// Marker used by the Phase 0 scaffold to prove the module links.
    public static let moduleName = "DesignSystem"
}

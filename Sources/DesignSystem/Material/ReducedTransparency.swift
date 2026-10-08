import AppKit
import SwiftUI

/// Whether materials should flatten to their base colour.
///
/// Reads `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` by
/// default — the setting a user actually turns on — but is a *writable*
/// environment value rather than SwiftUI's own read-only
/// `accessibilityReduceTransparency`.
///
/// That distinction earns its keep twice. It lets the screenshot suite render
/// both paths and put the reduced one on disk beside the normal one, which is
/// the only way anyone can check that it still looks like the theme rather
/// than like a bug. And it means the whole material layer has exactly one
/// switch, so "does this respect the accessibility setting" is answered by
/// reading one file instead of auditing every component.
private struct ReduceTransparencyKey: EnvironmentKey {
    static var defaultValue: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

extension EnvironmentValues {
    public var rackReduceTransparency: Bool {
        get { self[ReduceTransparencyKey.self] }
        set { self[ReduceTransparencyKey.self] = newValue }
    }
}

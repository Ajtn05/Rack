import AppKit
import SwiftUI

/// What stands in for "Rack" in the menu bar: the same VU needle mid-
/// deflection as `Resources/AppIcon.icns`, at status-item scale.
///
/// Wraps a bundled `NSImage` marked `isTemplate` rather than drawing live —
/// the one exception, alongside the app icon itself, to the rest of this
/// codebase treating every visual as code rendered against a theme rather
/// than an imported asset. A live SwiftUI `Canvas` was the first attempt, and
/// it produced a correctly-sized, entirely blank status item: `NSStatusItem`
/// content has always meant `NSImage`, and `isTemplate` is specifically what
/// lets one monochrome bitmap sit correctly in both a light and a dark menu
/// bar — AppKit repaints it from the current appearance rather than this
/// asset carrying two versions of itself. There is no live-drawn equivalent
/// of that behaviour to reach for instead.
///
/// The bitmap itself is not hand-imported: `Scripts/generate-app-icon.swift`
/// draws `Resources/MenuBarIcon.png` from the same path-based geometry as the
/// Dock icon, so the mark stays defined as code and only its *rendering*, not
/// its authorship, differs from everything else on screen.
public struct MenuBarGlyph: View {
    public init() {}

    /// 18pt tall is the status-item convention every built-in menu bar glyph
    /// on macOS uses; matching it is what keeps Rack's mark sitting on the
    /// same baseline as the rest of the menu bar rather than looming over or
    /// shrinking beneath its neighbours.
    private static let displaySize = NSSize(width: 18, height: 18)

    private static let image: NSImage = {
        FileHandle.standardError.write(
            "DEBUG Bundle.main.bundlePath=\(Bundle.main.bundlePath)\n".data(using: .utf8)!
        )
        FileHandle.standardError.write(
            "DEBUG Bundle.main.url(forResource:)=\(String(describing: Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")))\n".data(using: .utf8)!
        )
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let loaded = NSImage(contentsOf: url)
        else {
            FileHandle.standardError.write("DEBUG MenuBarIcon failed to load, using blank fallback\n".data(using: .utf8)!)
            // No placeholder drawing here: an empty status item is a visible,
            // debuggable symptom on its own, and a fallback glyph would just
            // hide a packaging mistake — the icon not being copied into
            // `Contents/Resources` — behind something that looks like it
            // worked.
            return NSImage(size: displaySize)
        }
        loaded.size = displaySize
        loaded.isTemplate = true
        return loaded
    }()

    public var body: some View {
        Image(nsImage: Self.image)
    }
}

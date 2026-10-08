import AppKit
import SwiftUI

/// Plain macOS.
///
/// Standard materials, the user's accent colour, system fonts, and no
/// borders — one continuous surface rather than a stack of boxes. Adapts to
/// light and dark automatically, because every colour here is a semantic
/// system colour rather than a fixed value.
///
/// Its real job is to keep the other themes honest. One theme is
/// indistinguishable from hardcoding: it is only when a second exists, and
/// looks nothing like the first, that a token named `panelBackground` has to
/// actually mean something.
public struct SystemTheme: Theme {
    public let id = "system"
    public let displayName = "System"

    public init() {}

    /// A platform colour, nudged toward another one, **resolved per
    /// appearance**.
    ///
    /// The nudge has to happen inside a drawing appearance and be re-done for
    /// each one, which is what `NSColor(name:dynamicProvider:)` is for.
    /// Blending eagerly — writing `NSColor.secondaryLabelColor.blended(…)`
    /// straight into the token — looks equivalent and is not: a dynamic
    /// catalog colour has no components until an appearance is current, so
    /// the blend collapses and the result is a single fixed colour that no
    /// longer tracks light and dark at all. It measured 1.00:1 against its
    /// own background, which is what caught it.
    private static func nudged(
        _ base: @autoclosure @escaping () -> NSColor,
        toward target: @autoclosure @escaping () -> NSColor,
        by fraction: CGFloat
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var result = base()
            appearance.performAsCurrentDrawingAppearance {
                guard let from = base().usingColorSpace(.sRGB),
                      let to = target().usingColorSpace(.sRGB),
                      let blended = from.blended(withFraction: fraction, of: to)
                else { return }
                result = blended
            }
            return result
        })
    }

    /// `.secondaryLabelColor` pulled a third of the way toward the primary.
    ///
    /// Worth stating plainly, because it is a real finding rather than a
    /// preference: AppKit's own secondary label measures 3.95:1 against a
    /// light control surface, under the 4.5:1 WCAG asks for at caption size.
    /// Every macOS app that uses it for small text inherits that. This theme
    /// exists to look like the platform, so the colour is *derived from* the
    /// platform token rather than replaced by an invented one — it still
    /// tracks light and dark and any future change Apple makes, it is just
    /// nudged far enough to be readable.
    private var readableSecondary: Color {
        Self.nudged(NSColor.secondaryLabelColor, toward: NSColor.labelColor, by: 0.35)
    }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(nsColor: .windowBackgroundColor),
            panelBackground: Color(nsColor: .controlBackgroundColor),
            // Continuous panels draw no edge, so this is only used by the
            // separators between groups.
            panelBorder: Color(nsColor: .separatorColor),

            readoutBackground: Color(nsColor: .controlBackgroundColor),
            readoutForeground: Color(nsColor: .labelColor),
            readoutDim: Color(nsColor: .quaternaryLabelColor),

            meterNominal: Color.accentColor,
            meterHot: Color(nsColor: .systemRed),
            // `.labelColor`, not `.secondaryLabelColor`. Both are
            // translucent ink rather than opaque colour, and stacking one
            // partial-opacity grey (this) over another (`controlTrack`,
            // `.quaternaryLabelColor`) composited to two greys close enough
            // to read as one — a peak marker had almost nothing to mark.
            // `.labelColor` is the platform's own highest-contrast ink, which
            // is what a peak flash should be regardless of channel.
            meterHold: Color(nsColor: .labelColor),

            controlActive: Color.accentColor,
            controlIdle: Color(nsColor: .secondaryLabelColor),
            controlTrack: Color(nsColor: .quaternaryLabelColor),

            labelPrimary: Color(nsColor: .labelColor),
            labelSecondary: readableSecondary,

            // No needle meter exists yet to draw with these; standard
            // system semantics stand in until one does.
            meterFace: Color(nsColor: .controlBackgroundColor),
            // Same derivation as `labelSecondary`: scale markings are small
            // type on a light face.
            meterScale: readableSecondary,
            meterNeedle: Color(nsColor: .labelColor),
            // The platform red, darkened. `.systemRed` straight measures
            // 3.6:1 against a light control surface as small scale
            // markings — derived from the system colour rather than
            // replaced by an invented one, so it still tracks the platform.
            meterZoneWarning: Self.nudged(
                NSColor.systemRed, toward: NSColor.black, by: 0.3
            ),

            // Unused while `displayStyle` is `.printed` — paired with a
            // zero `displayGlowRadius` below rather than left unset.
            displayGlow: Color.accentColor,

            // Aliased to the existing knob colours exactly.
            // `.controlColor` is AppKit's own token for the face of a
            // control. This was `.quaternaryLabelColor`, which is a
            // translucent *ink* colour rather than a surface — it happened
            // to render as pale grey, but it meant the knob's face and the
            // indicator drawn on it were both nominally black.
            knobFace: Color(nsColor: .controlColor),
            knobIndicator: Color(nsColor: .labelColor),
            knobArc: Color.accentColor,
            knobRing: Color(nsColor: .separatorColor),

            // AppKit's own token for exactly this surface.
            buttonFace: Color(nsColor: .controlColor),

            // Unused while `panelRelief` is `.flat`. Semantic AppKit
            // colours that already mean exactly this, and already adapt to
            // light and dark on their own.
            panelHighlight: Color(nsColor: .highlightColor),
            panelShadow: Color(nsColor: .shadowColor),

            // One true accent, so both aliases point at it rather than one
            // being an arbitrary second colour with no reason behind it.
            accentWarm: Color.accentColor,
            accentCool: Color.accentColor
        )
    }

    public var typography: ThemeTypography {
        let display = Font.system(.title3, design: .monospaced)
        let label = Font.callout
        let brand = Font.headline

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .caption,
            readout: display,
            readoutUnit: .caption,
            label: label,
            caption: .caption,
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 12,
            panelSpacing: 12,
            controlSpacing: 10,
            tightSpacing: 6,
            faderTrackWidth: 4,
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 8,
            meterWidth: 132,
            knobDiameter: 44,
            readoutMinWidth: 62,
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 58,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            // No glow: `displayStyle` is `.printed`.
            displayGlowRadius: 0
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .continuous,
            displayStyle: .printed,
            cornerRadius: 8,
            // No panel background — `panelStyle` is `.continuous` — but a
            // hairline is what keeps a stack of units reading as a stack of
            // *units* rather than one undifferentiated page once there are
            // this many of them on screen at once.
            borderWidth: 1,
            showsCentreDetent: false,
            // The one theme that genuinely varies: it follows the system
            // appearance rather than committing to one, which is the whole
            // point of it existing — see the type's own doc comment.
            //
            // Read via the global default rather than
            // `NSApplication.shared.effectiveAppearance`: the latter is
            // main-actor-isolated, and `chrome` is read from contexts this
            // protocol makes no isolation promise about.
            isLight: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark",
            knobStyle: .flush,
            buttonStyle: .flat,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .bar
        )
    }

    // MARK: - Material layer
    //
    // Entirely flat and unlit, on purpose. This theme's whole job is to look
    // like the platform, and the platform does not simulate materials — a
    // bevel here would make it the odd one out rather than the neutral one.

    public var panelMaterial: ThemeMaterial { .flat(colors.panelBackground) }
    public var windowMaterial: ThemeMaterial { .flat(colors.windowBackground) }
    public var lighting: ThemeLighting { .standard }
    public var panelBevel: ThemeBevel { .none }
    public var knobBevel: ThemeBevel { .none }
    public var buttonBevel: ThemeBevel { .none }
    public var displayBevel: ThemeBevel { .none }
    public var knobMaterial: ThemeMaterial { .flat(colors.knobFace) }
    public var buttonMaterial: ThemeMaterial { .flat(colors.buttonFace) }
    public var meterFaceMaterial: ThemeMaterial { .flat(colors.meterFace) }
    public var meterGlass: ThemeMaterial? { nil }
    public var engraving: ThemeEngraving { .silkscreen }
    public var hardware: ThemeHardware { .none }

}

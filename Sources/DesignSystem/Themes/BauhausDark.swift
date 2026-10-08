import SwiftUI

/// `Bauhaus` at night.
///
/// The same restraint, inverted: charcoal panels instead of off-white, the
/// same single orange accent, the same Helvetica, the same absence of
/// gradients, bloom and relief. Nothing about the *design* changes — only
/// which end of the value scale it sits at.
///
/// Structure is delegated to `Bauhaus` rather than copied. Typography,
/// spacing and every structural choice are the light theme's, so the two
/// cannot drift apart: retuning the grid or the type in one retunes both,
/// which is what makes them a pair rather than two themes that happen to
/// resemble each other.
public struct BauhausDark: Theme {
    public let id = "bauhausDark"
    public let displayName = "Bauhaus Dark"

    public init() {}

    private let light = Bauhaus()

    private var ink: Color { Color(red: 0.115, green: 0.115, blue: 0.11) }
    private var accent: Color { Color(red: 0.95, green: 0.46, blue: 0.11) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: ink,
            // Equal to the window, as in the light theme: `panelStyle` is
            // `.continuous`, so this is never painted — it is what the ground
            // already reads as, not a second guess at it.
            panelBackground: ink,
            panelBorder: Color(red: 0.32, green: 0.32, blue: 0.315),

            readoutBackground: ink,
            // Ink becomes paper. Still not the accent — orange marks what is
            // interactive, not the ordinary digits of a level nobody touched.
            readoutForeground: Color(red: 0.91, green: 0.91, blue: 0.90),
            readoutDim: Color(red: 0.22, green: 0.22, blue: 0.215),

            // Neutral, as in the light theme: the accent is spent on the
            // lamps and the knob arc, not spread across every bar.
            meterNominal: Color(red: 0.74, green: 0.74, blue: 0.73),
            meterHot: accent,
            meterHold: Color(red: 0.52, green: 0.52, blue: 0.51),

            // A lamp, and free to be lamp-bright: nothing reverses text on
            // this colour.
            controlActive: accent,
            controlIdle: Color(red: 0.47, green: 0.47, blue: 0.465),
            controlTrack: Color(red: 0.19, green: 0.19, blue: 0.185),

            labelPrimary: Color(red: 0.92, green: 0.92, blue: 0.91),
            labelSecondary: Color(red: 0.74, green: 0.74, blue: 0.73),

            // Unused — `meterStyle` is `.bar` — but stated rather than guessed.
            meterFace: ink,
            meterScale: Color(red: 0.74, green: 0.74, blue: 0.73),
            meterNeedle: Color(red: 0.92, green: 0.92, blue: 0.91),
            meterZoneWarning: accent,

            displayGlow: accent,

            knobFace: Color(red: 0.18, green: 0.18, blue: 0.175),
            knobIndicator: Color(red: 0.93, green: 0.93, blue: 0.92),
            knobArc: accent,
            knobRing: Color(red: 0.32, green: 0.32, blue: 0.315),

            buttonFace: Color(red: 0.19, green: 0.19, blue: 0.185),

            // Unused — everything here is flat — but a dark theme's highlight
            // and shadow are two shades of the same grey, not white and black.
            panelHighlight: Color(red: 0.30, green: 0.30, blue: 0.295),
            panelShadow: Color(red: 0.05, green: 0.05, blue: 0.048),

            accentWarm: accent,
            accentCool: accent
        )
    }

    // Structure is the light theme's, verbatim.
    public var typography: ThemeTypography { light.typography }
    public var metrics: ThemeMetrics { light.metrics }

    public var chrome: ThemeChrome {
        var chrome = light.chrome
        chrome.isLight = false
        return chrome
    }

    // MARK: - Material layer
    //
    // Flat, and it means it — the same as the light theme. This is the one
    // pair where filling any of this in would be a bug rather than an
    // improvement.

    public var panelMaterial: ThemeMaterial { .flat(colors.panelBackground) }
    public var windowMaterial: ThemeMaterial { .flat(colors.windowBackground) }
    public var lighting: ThemeLighting { light.lighting }
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

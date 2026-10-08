import SwiftUI

/// A 1980s component hi-fi stack.
///
/// Dark brushed panels, teal fluorescent readouts, amber for anything engaged,
/// and separate units with visible edges — a stack of boxes bolted into a rack
/// rather than one continuous surface.
///
/// This file is one of the two places in Rack where a literal colour may
/// appear. Everything below is a decision about *this skin only*; anything
/// that would also be true of a different skin belongs in a component.
public struct TechnicsTheme: Theme {
    public let id = "technics"
    public let displayName = "Technics"

    public init() {}

    public var colors: ThemeColors {
        ThemeColors(
            // Not black. Real equipment of the period was a very dark warm
            // grey, and true black reads as a hole in the screen.
            windowBackground: Color(red: 0.07, green: 0.07, blue: 0.075),
            panelBackground: Color(red: 0.13, green: 0.13, blue: 0.14),
            panelBorder: Color(red: 0.28, green: 0.28, blue: 0.30),

            // The glass of a fluorescent display: darker than the panel it is
            // set into, and slightly blue.
            readoutBackground: Color(red: 0.04, green: 0.05, blue: 0.06),
            readoutForeground: Color(red: 0.35, green: 0.95, blue: 0.90),
            // Barely above the display background — what a gridline drawn on
            // this glass should read as: present when looked for, invisible
            // when not.
            readoutDim: Color(red: 0.07, green: 0.13, blue: 0.14),

            meterNominal: Color(red: 0.35, green: 0.95, blue: 0.90),
            // Louder than the amber used for engaged controls, so a clip does
            // not disappear into the chrome.
            meterHot: Color(red: 1.0, green: 0.25, blue: 0.18),
            meterHold: Color(red: 1.0, green: 0.78, blue: 0.35),

            // Amber for engaged, which is what the period used for anything
            // switched in.
            controlActive: Color(red: 1.0, green: 0.72, blue: 0.25),
            controlIdle: Color(red: 0.55, green: 0.55, blue: 0.58),
            controlTrack: Color(red: 0.06, green: 0.06, blue: 0.065),

            labelPrimary: Color(red: 0.88, green: 0.88, blue: 0.86),
            labelSecondary: Color(red: 0.56, green: 0.56, blue: 0.56),

            // No needle meter exists yet to draw with these, but the glass
            // this theme's fluorescent tubes sit behind is the natural face
            // for one when it does.
            meterFace: Color(red: 0.04, green: 0.05, blue: 0.06),
            meterScale: Color(red: 0.56, green: 0.56, blue: 0.56),
            // Amber, matching "anything engaged" everywhere else in this
            // theme rather than inventing a needle-specific hue.
            meterNeedle: Color(red: 1.0, green: 0.72, blue: 0.25),
            meterZoneWarning: Color(red: 1.0, green: 0.25, blue: 0.18),

            // The tubes' own colour — a bloom is more of the light already
            // being emitted, not a different one.
            displayGlow: Color(red: 0.35, green: 0.95, blue: 0.90),

            // Aliased to the existing knob colours exactly, so migrating to
            // the dedicated tokens does not move a pixel.
            knobFace: Color(red: 0.06, green: 0.06, blue: 0.065),
            knobIndicator: Color(red: 0.88, green: 0.88, blue: 0.86),
            knobArc: Color(red: 1.0, green: 0.72, blue: 0.25),
            knobRing: Color(red: 0.28, green: 0.28, blue: 0.30),

            // Mid-grey moulded caps on a black panel — lighter than the
            // face they sit on, which is how a button on this equipment
            // reads as something standing on the panel rather than a hole
            // cut into it.
            buttonFace: Color(red: 0.22, green: 0.22, blue: 0.235),

            // `panelRelief` is `.flat`, so no panel uses these — but a raised
            // button cap does, for its lit top rim, and that rim has to be
            // lighter than `buttonFace` above or it reads as a second shadow
            // rather than as an edge catching the light.
            panelHighlight: Color(red: 0.38, green: 0.38, blue: 0.39),
            panelShadow: Color(red: 0.03, green: 0.03, blue: 0.035),

            // This theme's two dominant hues, exactly as they already are.
            accentWarm: Color(red: 1.0, green: 0.72, blue: 0.25),
            accentCool: Color(red: 0.35, green: 0.95, blue: 0.90)
        )
    }

    public var typography: ThemeTypography {
        let display = Font.system(size: 20, weight: .medium, design: .monospaced)
        let label = Font.system(size: 11, weight: .medium)
        let brand = Font.system(size: 11, weight: .semibold).monospaced()

        return ThemeTypography(
            // Wide letter-spacing on silkscreened panel legends is the single
            // most recognisable thing about this equipment.
            unitTitle: brand,
            unitStatus: .system(size: 10, weight: .regular).monospaced(),
            // Fully monospaced, not merely .monospacedDigit(): on a display
            // this period-specific every glyph should occupy a cell, minus
            // signs and decimal points included.
            readout: display,
            readoutUnit: .system(size: 10, weight: .regular).monospaced(),
            label: label,
            caption: .system(size: 9, weight: .regular).monospaced(),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 12,
            panelSpacing: 8,
            controlSpacing: 10,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 10,
            meterWidth: 132,
            knobDiameter: 46,
            readoutMinWidth: 62,
            // Tall enough for ±15 dB to be legible, short enough that the
            // amplifier stays one band rather than becoming a second row.
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 58,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            // Unused: `displayStyle` is `.segmented`, not `.emissive`. This
            // theme's readouts sit behind glass rather than blooming through
            // it.
            displayGlowRadius: 0
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .segmented,
            cornerRadius: 3,
            borderWidth: 1,
            showsCentreDetent: true,
            isLight: false,
            knobStyle: .flush,
            buttonStyle: .raised,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .bar
        )
    }

    // MARK: - Material layer
    //
    // Stated explicitly even though most of it is flat: a dark brushed panel
    // of the period was a painted extrusion with no visible grain at this
    // size, and pretending otherwise would be the kind of texture-for-its-own-
    // sake this system is meant to avoid. The buttons are the one genuinely
    // moulded part, so they get the bevel.

    public var panelMaterial: ThemeMaterial { .flat(colors.panelBackground) }
    public var windowMaterial: ThemeMaterial { .flat(colors.windowBackground) }
    public var lighting: ThemeLighting { .standard }
    public var panelBevel: ThemeBevel { .none }
    public var knobBevel: ThemeBevel { .none }
    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.5, shadowOpacity: 0.6)
    }
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 1, style: .inset, highlightOpacity: 0.3, shadowOpacity: 0.5)
    }
    public var knobMaterial: ThemeMaterial { .flat(colors.knobFace) }
    public var buttonMaterial: ThemeMaterial { .flat(colors.buttonFace) }
    public var meterFaceMaterial: ThemeMaterial { .flat(colors.meterFace) }
    public var meterGlass: ThemeMaterial? { nil }
    public var engraving: ThemeEngraving { .silkscreen }
    public var hardware: ThemeHardware { .none }

}

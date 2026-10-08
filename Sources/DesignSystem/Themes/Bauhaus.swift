import SwiftUI

/// The Dieter Rams answer, and the most restrained theme in the set.
///
/// Off-white panels separated by whitespace rather than borders, one orange
/// accent and nothing else chromatic, Helvetica Neue throughout — no
/// exception for the readout, which gets tabular figures from
/// `.monospacedDigit()` rather than from a separate monospaced family. No
/// gradients, no bloom, no relief: everything reads as flat as it is.
public struct Bauhaus: Theme {
    public let id = "bauhaus"
    public let displayName = "Bauhaus"

    public init() {}

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(red: 0.94, green: 0.938, blue: 0.93),
            // Equal to `windowBackground`: `panelStyle` is `.continuous`, so
            // this is never actually painted, but it is what the window
            // background already reads as, not a second guess at it.
            panelBackground: Color(red: 0.94, green: 0.938, blue: 0.93),
            panelBorder: Color(red: 0.72, green: 0.72, blue: 0.71),

            readoutBackground: Color(red: 0.94, green: 0.938, blue: 0.93),
            // Ink, not the accent — "single orange accent" means orange
            // marks what is interactive or worth noticing, not the ordinary
            // digits of a level nobody has touched.
            readoutForeground: Color(red: 0.13, green: 0.13, blue: 0.12),
            readoutDim: Color(red: 0.82, green: 0.82, blue: 0.81),

            // Neutral, deliberately — the orange is spent on `controlActive`
            // and `knobArc`, not spread across every bar in the equalizer.
            meterNominal: Color(red: 0.30, green: 0.30, blue: 0.29),
            meterHot: Color(red: 0.88, green: 0.40, blue: 0.05),
            meterHold: Color(red: 0.50, green: 0.50, blue: 0.49),

            // A deeper shade of the one accent, not a second colour: this
            // is what sits *behind* a selected chip's reversed text, and
            // the brighter orange below it does not clear that text at 3:1.
            controlActive: Color(red: 0.55, green: 0.24, blue: 0.02),
            // Darker than the obvious mid grey, for the same reason
            // `labelSecondary` is: against a ground this light there is very
            // little room before a disabled control stops being visible at
            // all rather than reading as unavailable.
            controlIdle: Color(red: 0.50, green: 0.50, blue: 0.49),
            controlTrack: Color(red: 0.88, green: 0.88, blue: 0.87),

            labelPrimary: Color(red: 0.13, green: 0.13, blue: 0.12),
            // As dark as it is mostly to clear 3:1 against a panel this
            // light at caption size — the honest cost of an off-white
            // ground and a secondary tone that still has to be read.
            labelSecondary: Color(red: 0.27, green: 0.27, blue: 0.26),

            // No needle meter exists yet — `meterStyle` is `.bar` — so
            // these are unused, filled in rather than left as a guess.
            meterFace: Color(red: 0.94, green: 0.938, blue: 0.93),
            // Dark enough to clear 4.5:1 against the off-white face as
            // printed markings — a mid grey measured 3.5:1 there.
            meterScale: Color(red: 0.40, green: 0.40, blue: 0.39),
            meterNeedle: Color(red: 0.13, green: 0.13, blue: 0.12),
            // A deeper orange than the accent: this is printed ink on a
            // light meter card, not a lit bar, and the brighter accent
            // measured 3.0:1 against it.
            meterZoneWarning: Color(red: 0.66, green: 0.30, blue: 0.04),

            // Unused: `displayStyle` is `.printed`, paired with a zero
            // `displayGlowRadius` below.
            displayGlow: Color(red: 0.88, green: 0.40, blue: 0.05),

            // Flush knobs have no dimension to draw, so these are the same
            // flat treatment as everything else — a light face, dark
            // indicator line, the one accent for the value arc.
            knobFace: Color(red: 0.90, green: 0.90, blue: 0.89),
            knobIndicator: Color(red: 0.13, green: 0.13, blue: 0.12),
            knobArc: Color(red: 0.88, green: 0.40, blue: 0.05),
            knobRing: Color(red: 0.72, green: 0.72, blue: 0.71),

            // The same flat grey the grooves use — this theme has no
            // relief to distinguish a cap with, and does not want any.
            buttonFace: Color(red: 0.88, green: 0.88, blue: 0.87),

            // Unused — `panelRelief` is `.flat` and `knobStyle` is `.flush`,
            // and this theme means it: "no gradients, no bloom, no relief."
            panelHighlight: Color(red: 0.98, green: 0.978, blue: 0.97),
            panelShadow: Color(red: 0.84, green: 0.84, blue: 0.83),

            // One accent means both aliases point at the brighter, more
            // saturated version of it — nothing here reverses text on top
            // of them, so nothing forces the darker shade `controlActive`
            // needs.
            accentWarm: Color(red: 0.88, green: 0.40, blue: 0.05),
            accentCool: Color(red: 0.88, green: 0.40, blue: 0.05)
        )
    }

    public var typography: ThemeTypography {
        // Helvetica Neue ships with every Mac, so this needs no bundled
        // font asset to say "Helvetica or Inter throughout" and mean it.
        func helveticaNeue(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("Helvetica Neue", size: size).weight(weight)
        }

        let display = helveticaNeue(18)
        let label = helveticaNeue(10)
        let brand = helveticaNeue(10, weight: .bold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: helveticaNeue(9),
            readout: display,
            readoutUnit: helveticaNeue(9),
            label: label,
            caption: helveticaNeue(8),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            // Generous spacing, small type — the two halves of "restrained"
            // this theme actually asks for.
            panelPadding: 20,
            panelSpacing: 22,
            controlSpacing: 14,
            tightSpacing: 8,
            faderTrackWidth: 3,
            faderHeight: 116,
            faderCapHeight: 12,
            meterHeight: 7,
            meterWidth: 132,
            knobDiameter: 42,
            readoutMinWidth: 60,
            graphHeight: 104,
            traceWidth: 1.5,
            chipMinWidth: 56,
            windowTopInset: 28,
            iconSize: 17,
            appNameWidth: 120,
            displayGlowRadius: 0
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            // Whitespace, not filled boxes — but a hairline rule is still
            // what a strict grid draws between its own modules, and without
            // one this many flat panels in a row read as a single page
            // rather than the modular stack they are meant to be.
            panelStyle: .continuous,
            displayStyle: .printed,
            // A strict grid has no room for a rounded corner to soften.
            cornerRadius: 0,
            borderWidth: 1,
            showsCentreDetent: true,
            isLight: true,
            knobStyle: .flush,
            buttonStyle: .flat,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .bar
        )
    }

    // MARK: - Material layer
    //
    // Nothing, and it means it. "No gradients, no bloom, no relief" is this
    // theme's whole identity, so every material is flat and every bevel is
    // absent — this is the one skin where filling these in with anything
    // would be a bug rather than an improvement.

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

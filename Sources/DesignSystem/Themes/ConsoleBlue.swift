import SwiftUI

/// The British console preamp.
///
/// Navy painted steel with the faintest orange peel, a brushed silver
/// extrusion capping every panel, and white lettering cut into the paint.
/// Knob caps are colour-coded the way console hardware always has been —
/// oxblood for level, deep blue for shaping — with white indicator lines and
/// chrome skirts. Cream VU faces, red needles, black printed scales, behind
/// glass.
///
/// Warm and saturated. The silver strip is the only cool thing on the panel,
/// which is exactly why it reads as metal rather than as another colour.
public struct ConsoleBlue: Theme {
    public let id = "consoleBlue"
    public let displayName = "ConsoleBlue"

    public init() {}

    private var navy: Color { Color(red: 0.13, green: 0.20, blue: 0.34) }
    private var navyDeep: Color { Color(red: 0.09, green: 0.14, blue: 0.25) }
    private var silver: Color { Color(red: 0.72, green: 0.74, blue: 0.77) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: navyDeep,
            panelBackground: navy,
            // Chrome trim between units.
            panelBorder: Color(red: 0.55, green: 0.58, blue: 0.63),

            // Meter and counter windows are genuinely dark behind their glass.
            readoutBackground: Color(red: 0.05, green: 0.07, blue: 0.11),
            // Warm amber against all that blue — the one place the panel
            // emits rather than reflects.
            readoutForeground: Color(red: 1.0, green: 0.74, blue: 0.36),
            readoutDim: Color(red: 0.16, green: 0.19, blue: 0.26),

            meterNominal: Color(red: 0.72, green: 0.78, blue: 0.86),
            meterHot: Color(red: 0.88, green: 0.24, blue: 0.18),
            meterHold: Color(red: 0.95, green: 0.72, blue: 0.34),

            // A *lit* lamp red, not the oxblood of the caps.
            //
            // This started as the cap colour on the reasoning that the switch
            // row should tie to the knobs, and measured 1.3:1 against the
            // navy — a lamp you cannot tell is on. The habit it came from is
            // obsolete: `controlActive` used to sit behind reversed chip
            // text and had to be dark enough to carry it, but since buttons
            // grew real lamps the legend is always `labelPrimary` on the
            // panel and nothing reverses on this colour at all. It is free to
            // be as bright as a lamp actually is.
            controlActive: Color(red: 0.95, green: 0.35, blue: 0.28),
            // Lighter than the obvious mid grey — against a dark navy a
            // disabled control has to come *up* to stay visible, not down.
            controlIdle: Color(red: 0.50, green: 0.54, blue: 0.61),
            controlTrack: Color(red: 0.10, green: 0.15, blue: 0.26),

            // Engraved white lettering — the console standard.
            labelPrimary: Color(red: 0.94, green: 0.95, blue: 0.96),
            labelSecondary: Color(red: 0.74, green: 0.78, blue: 0.84),

            // Cream card, black printed scale, red needle.
            meterFace: Color(red: 0.91, green: 0.87, blue: 0.77),
            meterScale: Color(red: 0.11, green: 0.10, blue: 0.09),
            meterNeedle: Color(red: 0.72, green: 0.12, blue: 0.10),
            meterZoneWarning: Color(red: 0.60, green: 0.10, blue: 0.08),

            displayGlow: Color(red: 1.0, green: 0.74, blue: 0.36),

            // The oxblood level cap.
            knobFace: Color(red: 0.35, green: 0.09, blue: 0.11),
            knobIndicator: Color(red: 0.97, green: 0.97, blue: 0.97),
            knobArc: Color(red: 0.95, green: 0.72, blue: 0.34),
            // Chrome skirt ring.
            knobRing: Color(red: 0.78, green: 0.80, blue: 0.83),

            // Moulded caps a shade above the navy they stand on.
            buttonFace: Color(red: 0.21, green: 0.28, blue: 0.42),

            panelHighlight: Color(red: 0.44, green: 0.52, blue: 0.66),
            panelShadow: Color(red: 0.03, green: 0.05, blue: 0.09),

            accentWarm: Color(red: 0.52, green: 0.11, blue: 0.13),
            accentCool: silver
        )
    }

    public var typography: ThemeTypography {
        // Condensed, uppercase-friendly grotesque — the face console legends
        // are actually screened and cut in.
        let display = Font.system(size: 18, weight: .semibold, design: .monospaced)
        let label = Font.system(size: 10, weight: .semibold)
        let brand = Font.system(size: 10.5, weight: .heavy)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 9, weight: .medium),
            readout: display,
            readoutUnit: .system(size: 9, weight: .medium),
            label: label,
            caption: .system(size: 8.5, weight: .medium),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 14,
            panelSpacing: 8,
            controlSpacing: 11,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 10,
            meterWidth: 132,
            // Console knobs are chunky.
            knobDiameter: 50,
            readoutMinWidth: 62,
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 58,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            displayGlowRadius: 3
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .emissive,
            cornerRadius: 3,
            borderWidth: 1,
            showsCentreDetent: true,
            isLight: false,
            knobStyle: .raised,
            knobIndicatorStyle: .line,
            buttonStyle: .raised,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer

    /// Painted steel: a broad sheen plus the faint undulation of a finish
    /// that did not flow out perfectly flat. Kept very low — orange peel you
    /// can *see* is a defect, not a texture.
    public var panelMaterial: ThemeMaterial {
        .paintedSteel(base: navy, sheen: 0.13, orangePeel: 0.045)
    }

    public var windowMaterial: ThemeMaterial {
        .paintedSteel(base: navyDeep, sheen: 0.08, orangePeel: 0.035)
    }

    /// Low and hard: a console is lit by whatever is above the desk, and its
    /// chrome catches it sharply.
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.5, ambient: 0.38, specular: 0.6)
    }

    public var panelBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.35, shadowOpacity: 0.55)
    }

    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 3, style: .rounded, highlightOpacity: 0.45, shadowOpacity: 0.6)
    }

    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.45, shadowOpacity: 0.55)
    }

    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.35, shadowOpacity: 0.65)
    }

    /// Oxblood, for level and routing.
    public var knobMaterial: ThemeMaterial {
        .bakelite(base: Color(red: 0.35, green: 0.09, blue: 0.11), mottle: 0.045)
    }

    /// Deep blue, for shaping. The colour-coding is informative rather than
    /// decorative: on a real desk it tells you which group a control belongs
    /// to before you have read its legend.
    public var knobAlternateMaterial: ThemeMaterial? {
        .bakelite(base: Color(red: 0.13, green: 0.22, blue: 0.42), mottle: 0.045)
    }

    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.21, green: 0.28, blue: 0.42))
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.91, green: 0.87, blue: 0.77))
    }

    /// Glass over the VU, weak enough to read the printed scale through.
    public var meterGlass: ThemeMaterial? {
        .glass(
            tint: Color(red: 1, green: 1, blue: 1).opacity(0.02),
            reflection: 0.18, curvature: 0.55
        )
    }

    /// Cut into the paint and filled white.
    public var engraving: ThemeEngraving {
        .etched(fill: Color(red: 0.94, green: 0.95, blue: 0.96))
    }

    /// Hex screws at the corners, and the brushed extrusion capping every
    /// panel. Rack ears are off to match `RackSteel` — the flanges cost two
    /// strips of window width, and that decision was taken once for the whole
    /// set rather than per theme.
    public var hardware: ThemeHardware {
        ThemeHardware(
            screws: .hex,
            rackEars: false,
            topStrip: .brushedMetal(
                base: silver, axis: .horizontal, grainScale: 1.2, grainOpacity: 0.13
            )
        )
    }
}

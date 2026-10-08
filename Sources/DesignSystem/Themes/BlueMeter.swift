import SwiftUI

/// The 1970s American separates look.
///
/// Black glass fronts, deep blue illuminated meter faces, brass trim on
/// every border and knob ring, and readouts that actually bloom. Warm metal
/// against cold blue, and the most dimensional of the six themes: raised
/// knobs, an emissive display style, a needle meter waiting for Part 2.
public struct BlueMeter: Theme {
    public let id = "blueMeter"
    public let displayName = "BlueMeter"

    public init() {}

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(red: 0.045, green: 0.045, blue: 0.05),
            panelBackground: Color(red: 0.08, green: 0.08, blue: 0.095),
            panelBorder: Color(red: 0.72, green: 0.58, blue: 0.28),

            // The meter face's own deep blue, dark enough that white text and
            // a real bloom both read clearly against it.
            readoutBackground: Color(red: 0.04, green: 0.10, blue: 0.30),
            readoutForeground: Color(red: 0.90, green: 0.94, blue: 1.0),
            readoutDim: Color(red: 0.14, green: 0.20, blue: 0.42),

            // The interim bar meter, until Part 2's needle exists — cold
            // blue for normal level, matching the theme's other hand.
            meterNominal: Color(red: 0.45, green: 0.78, blue: 1.0),
            meterHot: Color(red: 1.0, green: 0.28, blue: 0.20),
            meterHold: Color(red: 0.78, green: 0.62, blue: 0.30),

            // Brass, not the cold blue — "anything engaged" is warm metal
            // switching in, the same read Technics' amber gives.
            controlActive: Color(red: 0.80, green: 0.62, blue: 0.28),
            controlIdle: Color(red: 0.38, green: 0.40, blue: 0.46),
            controlTrack: Color(red: 0.11, green: 0.11, blue: 0.13),

            labelPrimary: Color(red: 0.92, green: 0.92, blue: 0.90),
            labelSecondary: Color(red: 0.58, green: 0.55, blue: 0.48),

            meterFace: Color(red: 0.04, green: 0.10, blue: 0.30),
            meterScale: Color(red: 0.95, green: 0.95, blue: 0.98),
            // The classic red VU pointer. This was a dark warm brown, on the
            // reasoning that a needle is a physical part rather than a lit
            // one — true, but the face it points against is a deep
            // *illuminated* blue, and dark-on-dark measured 1.03:1. A needle
            // you cannot find is worse than one that is not strictly a light
            // source, and red keeps it distinct from the white scale as well.
            meterNeedle: Color(red: 0.95, green: 0.30, blue: 0.22),
            meterZoneWarning: Color(red: 1.0, green: 0.30, blue: 0.20),

            // The tubes' own colour: a bloom is more of the light already
            // being emitted, not a different one.
            displayGlow: Color(red: 0.55, green: 0.75, blue: 1.0),

            knobFace: Color(red: 0.10, green: 0.10, blue: 0.11),
            knobIndicator: Color(red: 0.92, green: 0.92, blue: 0.90),
            knobArc: Color(red: 0.80, green: 0.62, blue: 0.28),
            // The brass ring, literally.
            knobRing: Color(red: 0.78, green: 0.62, blue: 0.30),

            // Dark caps, but clearly proud of the near-black glass front.
            buttonFace: Color(red: 0.19, green: 0.19, blue: 0.21),

            panelHighlight: Color(red: 0.30, green: 0.27, blue: 0.20),
            panelShadow: Color(red: 0.02, green: 0.02, blue: 0.02),

            accentWarm: Color(red: 0.80, green: 0.62, blue: 0.28),
            accentCool: Color(red: 0.30, green: 0.55, blue: 0.95)
        )
    }

    public var typography: ThemeTypography {
        // A clean geometric sans for everything but the readouts, which get
        // a tabular monospaced face so a climbing number does not jitter
        // the moment it starts blooming.
        let display = Font.system(size: 20, weight: .medium, design: .monospaced)
        let label = Font.system(size: 11, weight: .medium)
        let brand = Font.system(size: 11, weight: .bold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 10, weight: .semibold),
            readout: display,
            readoutUnit: .system(size: 10, weight: .medium),
            label: label,
            caption: .system(size: 9, weight: .regular),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 13,
            panelSpacing: 9,
            controlSpacing: 11,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 114,
            faderCapHeight: 15,
            meterHeight: 11,
            meterWidth: 132,
            // Large — knobs are the whole point of this look.
            knobDiameter: 50,
            readoutMinWidth: 64,
            graphHeight: 106,
            traceWidth: 2,
            chipMinWidth: 60,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            // Real bloom, sized to be seen without smearing the digits
            // underneath it into mush.
            displayGlowRadius: 4
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .emissive,
            cornerRadius: 4,
            borderWidth: 1.5,
            showsCentreDetent: true,
            isLight: false,
            knobStyle: .raised,
            buttonStyle: .raised,
            // "Black glass front" is flat and glossy, not bevelled — the
            // dimension in this look lives in the knobs, not the panels.
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer
    //
    // Black glass front, brass trim: the panel is a glossy painted sheet
    // rather than a brushed one, and the knobs are moulded caps inside brass
    // rings. Deep blue meter faces behind real glass.

    public var panelMaterial: ThemeMaterial {
        .paintedSteel(
            base: Color(red: 0.08, green: 0.08, blue: 0.095), sheen: 0.14, orangePeel: 0.05
        )
    }
    public var windowMaterial: ThemeMaterial {
        .flat(Color(red: 0.045, green: 0.045, blue: 0.05))
    }
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.5, ambient: 0.35, specular: 0.6)
    }
    public var panelBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.35, shadowOpacity: 0.5)
    }
    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .rounded, highlightOpacity: 0.4, shadowOpacity: 0.6)
    }
    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.4, shadowOpacity: 0.6)
    }
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.3, shadowOpacity: 0.7)
    }
    public var knobMaterial: ThemeMaterial {
        .bakelite(base: Color(red: 0.10, green: 0.10, blue: 0.11), mottle: 0.05)
    }
    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.19, green: 0.19, blue: 0.21))
    }
    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.04, green: 0.10, blue: 0.30))
    }
    public var meterGlass: ThemeMaterial? {
        .glass(tint: Color(red: 1, green: 1, blue: 1).opacity(0.02), reflection: 0.20, curvature: 0.6)
    }
    public var engraving: ThemeEngraving { .silkscreen }
    public var hardware: ThemeHardware { ThemeHardware(screws: .hex) }

}

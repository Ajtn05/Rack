import SwiftUI

/// A studio tape machine.
///
/// Pale seafoam enamel with a soft gloss, chrome bezels, cream meter faces
/// with red needles. Big flat transport-style buttons that press *into* the
/// panel. Red counters. Black legends screened straight onto the paint —
/// silkscreen, not engraving, because a machine of this kind was finished in
/// one pass and lettered afterwards.
///
/// Cooler and calmer than `ConsoleBlue`. A console is a thing you play; a tape
/// machine is a thing you set running and watch, and the panel should feel
/// like the second of those.
public struct TapeMachine: Theme {
    public let id = "tapeMachine"
    public let displayName = "TapeMachine"

    public init() {}

    private var seafoam: Color { Color(red: 0.69, green: 0.77, blue: 0.72) }
    private var seafoamDeep: Color { Color(red: 0.60, green: 0.68, blue: 0.64) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: seafoamDeep,
            panelBackground: seafoam,
            // Chrome.
            panelBorder: Color(red: 0.52, green: 0.56, blue: 0.55),

            // The counter window: near-black, with red digits in it.
            readoutBackground: Color(red: 0.09, green: 0.08, blue: 0.08),
            readoutForeground: Color(red: 1.0, green: 0.32, blue: 0.24),
            // Neutral, not a dark red. `readoutDim` also draws the *unlit*
            // portion of a spectrum bar, and derived from the counter red it
            // put a dark red block above every bar — which reads as a hot
            // signal rather than as empty scale. A dim mark on glass should
            // be dim, not tinted.
            readoutDim: Color(red: 0.17, green: 0.16, blue: 0.16),

            // Dark, for the fader-mounted meters (`LevelSlider`, the EQ
            // fills, `LevelMeter`'s channel bars): ink against the seafoam
            // groove, not light.
            meterNominal: Color(red: 0.20, green: 0.24, blue: 0.23),
            meterHot: Color(red: 0.70, green: 0.16, blue: 0.11),
            // `LevelMeter`'s peak flash only — see `readoutHold` for the
            // spectrum's own peak marker below. This one just has to clear
            // `controlTrack`, and a deep maroon does; it does not also have
            // to work on the display glass the way `RackSteel`'s or
            // `Champagne`'s single `meterHold` manages to, because on this
            // theme no colour can do both: `controlTrack` here is bright
            // enough that even white measures under 3:1 against it.
            meterHold: Color(red: 0.50, green: 0.09, blue: 0.05),

            // Engaged is the transport red.
            controlActive: Color(red: 0.50, green: 0.12, blue: 0.09),
            // Darker than it looks like it needs: the seafoam panel is light
            // enough that a mid grey measured 2.8:1 against it.
            controlIdle: Color(red: 0.35, green: 0.39, blue: 0.38),
            controlTrack: Color(red: 0.54, green: 0.61, blue: 0.58),

            labelPrimary: Color(red: 0.10, green: 0.12, blue: 0.12),
            labelSecondary: Color(red: 0.22, green: 0.25, blue: 0.25),

            // Cream card, red needle, black scale — the studio standard.
            meterFace: Color(red: 0.92, green: 0.89, blue: 0.81),
            meterScale: Color(red: 0.11, green: 0.10, blue: 0.09),
            meterNeedle: Color(red: 0.72, green: 0.13, blue: 0.10),
            meterZoneWarning: Color(red: 0.58, green: 0.10, blue: 0.07),

            displayGlow: Color(red: 1.0, green: 0.32, blue: 0.24),

            // Cream transport caps against the green.
            knobFace: Color(red: 0.86, green: 0.85, blue: 0.80),
            knobIndicator: Color(red: 0.10, green: 0.12, blue: 0.12),
            knobArc: Color(red: 0.50, green: 0.12, blue: 0.09),
            knobRing: Color(red: 0.74, green: 0.77, blue: 0.76),

            // Large flat transport buttons, a touch lighter than the panel.
            buttonFace: Color(red: 0.76, green: 0.82, blue: 0.79),

            panelHighlight: Color(red: 0.90, green: 0.94, blue: 0.92),
            panelShadow: Color(red: 0.34, green: 0.39, blue: 0.37),

            accentWarm: Color(red: 0.50, green: 0.12, blue: 0.09),
            accentCool: Color(red: 0.74, green: 0.77, blue: 0.76),

            // The spectrum's own lit colour: the transport red, brightened,
            // rather than the dark ink `meterNominal` reads as against a
            // fader groove. That dark green measured under 2:1 on the near-
            // black display glass the spectrum actually draws on.
            readoutLevel: Color(red: 0.95, green: 0.34, blue: 0.24),

            // The spectrum's own peak marker — see the note on `meterHold`
            // above for why this theme needs the split at all. A warm
            // near-white, the way a VU peak lamp actually reads regardless
            // of the needle's own colour.
            readoutHold: Color(red: 1.0, green: 0.97, blue: 0.90)
        )
    }

    public var typography: ThemeTypography {
        // The counter gets a tabular face rather than a faked seven-segment
        // one. A genuine segment renderer would need real segment geometry
        // and still could not set `CTR`, `−∞` or `RUNNING`, which this same
        // component has to show — see `Readout`. Red digits on black in a
        // clean mono is the honest version of the same idea.
        let display = Font.system(size: 18, weight: .medium, design: .monospaced)
        let label = Font.system(size: 10, weight: .medium)
        let brand = Font.system(size: 10.5, weight: .bold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 9, weight: .regular),
            readout: display,
            readoutUnit: .system(size: 9, weight: .regular),
            label: label,
            caption: .system(size: 8.5, weight: .regular),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 13,
            // Tight, because the seams are what separate the units here.
            panelSpacing: 5,
            controlSpacing: 11,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 112,
            // Big transport-style caps.
            faderCapHeight: 16,
            meterHeight: 10,
            meterWidth: 132,
            knobDiameter: 46,
            readoutMinWidth: 62,
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 62,
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
            isLight: true,
            knobStyle: .raised,
            // A dot rather than a line: transport-era controls used a moulded
            // pip, and it reads more calmly than a full radial stripe.
            knobIndicatorStyle: .dot,
            buttonStyle: .raised,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer

    /// Baked enamel: near-flat with a soft fall of light across it. Glossier
    /// than `RackSteel`'s brushed sheet and far calmer than `ConsoleBlue`'s
    /// painted steel.
    public var panelMaterial: ThemeMaterial {
        .enamel(base: seafoam, gloss: 0.13)
    }

    public var windowMaterial: ThemeMaterial {
        .enamel(base: seafoamDeep, gloss: 0.09)
    }

    /// High and soft. A machine room is lit flatly from above, and this is
    /// most of why the theme reads calmer than the console.
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.72, ambient: 0.6, specular: 0.42)
    }

    public var panelBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.5, shadowOpacity: 0.35)
    }

    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .rounded, highlightOpacity: 0.5, shadowOpacity: 0.4)
    }

    /// **Inset**, unlike every other theme here: a transport button is a big
    /// flat cap that sits down in a recess, so it reads as pressed *into* the
    /// panel even at rest. Engaged, `.inverted` lifts it — which is the right
    /// way round for this one and the wrong way round for everything else.
    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.5, shadowOpacity: 0.4)
    }

    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.45, shadowOpacity: 0.5)
    }

    public var knobMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.86, green: 0.85, blue: 0.80), gloss: 0.12)
    }

    public var buttonMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.76, green: 0.82, blue: 0.79), gloss: 0.10)
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.92, green: 0.89, blue: 0.81))
    }

    public var meterGlass: ThemeMaterial? {
        .glass(
            tint: Color(red: 1, green: 1, blue: 1).opacity(0.02),
            reflection: 0.15, curvature: 0.45
        )
    }

    /// Screened on, not cut in — the black legends sit on top of the enamel.
    public var engraving: ThemeEngraving { .silkscreen }

    /// Slotted screws, and the visible seam where one chassis ends and the
    /// next begins.
    public var hardware: ThemeHardware {
        ThemeHardware(screws: .slotted, panelSeams: true)
    }
}

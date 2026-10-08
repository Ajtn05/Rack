import SwiftUI

/// A pre-war domestic radio.
///
/// Dark brown mottled bakelite, an ivory dial window behind curved glass,
/// gold-tone trim, and cloth grille wherever the cabinet has nothing else to
/// do. Readouts glow like a filament rather than a phosphor — warm, and never
/// quite white.
///
/// The most stylised of the set, and therefore the one where restraint matters
/// most. Everything here is one step quieter than it wants to be: the mottle
/// is barely there, the gold is a trim colour rather than a finish, and the
/// grille is confined to the window behind the panels. Turned up even slightly
/// this stops being a radio and becomes a pastiche of one.
public struct Bakelite: Theme {
    public let id = "bakelite"
    public let displayName = "Bakelite"

    public init() {}

    private var phenolic: Color { Color(red: 0.22, green: 0.14, blue: 0.09) }
    private var phenolicDeep: Color { Color(red: 0.15, green: 0.10, blue: 0.06) }
    private var gold: Color { Color(red: 0.78, green: 0.63, blue: 0.32) }
    private var ivory: Color { Color(red: 0.93, green: 0.89, blue: 0.78) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: phenolicDeep,
            panelBackground: phenolic,
            panelBorder: Color(red: 0.55, green: 0.44, blue: 0.22),

            // The dial window: ivory card lit from behind by a filament.
            readoutBackground: Color(red: 0.19, green: 0.13, blue: 0.07),
            // Incandescent, not fluorescent — this is a hot wire behind a
            // celluloid scale, so it is warm and slightly orange rather than
            // the cold green a later set would use.
            readoutForeground: Color(red: 1.0, green: 0.80, blue: 0.48),
            readoutDim: Color(red: 0.30, green: 0.21, blue: 0.11),

            meterNominal: Color(red: 0.84, green: 0.70, blue: 0.40),
            meterHot: Color(red: 0.80, green: 0.28, blue: 0.14),
            meterHold: Color(red: 0.90, green: 0.78, blue: 0.52),

            // A filament coming up to temperature. Deepened gold measured
            // 2.0:1 against the phenolic — see the note in `ConsoleBlue`:
            // nothing reverses text on this colour any more, so a lamp can
            // be lamp-bright.
            controlActive: Color(red: 1.0, green: 0.82, blue: 0.45),
            // Lifted, for the same reason as `ConsoleBlue`'s — a dark
            // cabinet needs its disabled controls brighter, not dimmer.
            controlIdle: Color(red: 0.54, green: 0.46, blue: 0.35),
            controlTrack: Color(red: 0.16, green: 0.11, blue: 0.07),

            // Aged ivory lettering rather than white: nothing on a set this
            // old is still white.
            labelPrimary: Color(red: 0.93, green: 0.88, blue: 0.76),
            labelSecondary: Color(red: 0.78, green: 0.71, blue: 0.58),

            // The dial card, and an ivory pointer on it.
            meterFace: Color(red: 0.90, green: 0.85, blue: 0.72),
            meterScale: Color(red: 0.20, green: 0.13, blue: 0.07),
            meterNeedle: Color(red: 0.32, green: 0.19, blue: 0.09),
            meterZoneWarning: Color(red: 0.62, green: 0.16, blue: 0.08),

            displayGlow: Color(red: 1.0, green: 0.74, blue: 0.38),

            // Chrome caps inside brass rings.
            knobFace: Color(red: 0.78, green: 0.78, blue: 0.79),
            knobIndicator: Color(red: 0.16, green: 0.11, blue: 0.07),
            knobArc: gold,
            knobRing: Color(red: 0.72, green: 0.57, blue: 0.28),

            // Moulded phenolic caps, lighter than the cabinet.
            buttonFace: Color(red: 0.32, green: 0.22, blue: 0.14),

            panelHighlight: Color(red: 0.52, green: 0.40, blue: 0.26),
            panelShadow: Color(red: 0.06, green: 0.04, blue: 0.02),

            accentWarm: gold,
            accentCool: Color(red: 0.78, green: 0.78, blue: 0.79)
        )
    }

    public var typography: ThemeTypography {
        // A period grotesque with a bit of weight — dial lettering of the era
        // was drawn, not set, and reads heavier than a modern UI face.
        let display = Font.system(size: 17, weight: .medium, design: .serif)
        let label = Font.system(size: 10, weight: .medium, design: .serif)
        let brand = Font.system(size: 11, weight: .bold, design: .serif)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 9, weight: .regular, design: .serif),
            readout: display,
            readoutUnit: .system(size: 9, weight: .regular, design: .serif),
            label: label,
            caption: .system(size: 8.5, weight: .regular, design: .serif),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 14,
            panelSpacing: 10,
            controlSpacing: 12,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 10,
            meterWidth: 132,
            knobDiameter: 50,
            readoutMinWidth: 62,
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 60,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            // A filament blooms more than a phosphor does.
            displayGlowRadius: 4
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .emissive,
            // Moulded, so everything is generously radiused.
            cornerRadius: 9,
            borderWidth: 1.5,
            showsCentreDetent: true,
            isLight: false,
            knobStyle: .raised,
            // A notch cut into the chrome cap, which is what a moulded
            // pointer knob of this period actually has.
            knobIndicatorStyle: .notch,
            buttonStyle: .raised,
            panelRelief: .raised,
            usesSideCheeks: true,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer

    /// Moulded phenolic: warped, blotchy, darker in the hollows. The mottle
    /// is the single most over-doable number in this whole system — at
    /// anything above about 0.06 it stops reading as a moulding and starts
    /// reading as damp.
    public var panelMaterial: ThemeMaterial {
        .bakelite(base: phenolic, mottle: 0.055)
    }

    /// Cloth grille behind the panels. This is the "large empty area" the
    /// brief asks for it on — confined to the window background, where it
    /// reads as the speaker cloth a cabinet is fronted with rather than as a
    /// pattern applied to everything.
    public var windowMaterial: ThemeMaterial {
        .clothGrille(base: phenolicDeep, weaveScale: 3)
    }

    /// Warm and soft, and lower than the others — a domestic set is lit by a
    /// room, not by a light rig.
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.58, ambient: 0.52, specular: 0.45)
    }

    /// The one theme whose panels genuinely stand proud: a bakelite cabinet
    /// is moulded in relief, not milled flat.
    public var panelBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .raised, highlightOpacity: 0.4, shadowOpacity: 0.55)
    }

    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 3, style: .rounded, highlightOpacity: 0.55, shadowOpacity: 0.5)
    }

    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .raised, highlightOpacity: 0.45, shadowOpacity: 0.5)
    }

    /// The dial window is set deep into the moulding.
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .inset, highlightOpacity: 0.4, shadowOpacity: 0.65)
    }

    /// Chrome caps — polished metal, so anodised rather than moulded.
    public var knobMaterial: ThemeMaterial {
        .anodised(base: Color(red: 0.78, green: 0.78, blue: 0.79), grainOpacity: 0.08)
    }

    public var buttonMaterial: ThemeMaterial {
        .bakelite(base: Color(red: 0.32, green: 0.22, blue: 0.14), mottle: 0.05)
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.90, green: 0.85, blue: 0.72))
    }

    /// Curved glass over the dial — the highest curvature in the set, because
    /// a dial window of this period genuinely was a bent pane.
    public var meterGlass: ThemeMaterial? {
        .glass(
            tint: Color(red: 1, green: 1, blue: 1).opacity(0.02),
            reflection: 0.18, curvature: 0.8
        )
    }

    /// Cut into the moulding and filled with gold.
    public var engraving: ThemeEngraving { .etched(fill: gold) }

    /// Wood cabinet cheeks — the case a set like this is actually built into.
    public var hardware: ThemeHardware {
        ThemeHardware(
            sideCheeks: .wood(
                .wood(
                    tone: Color(red: 0.34, green: 0.20, blue: 0.11),
                    grainScale: 24, figure: 0.4
                )
            )
        )
    }
}

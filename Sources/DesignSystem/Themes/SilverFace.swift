import SwiftUI

/// A late-70s Japanese receiver.
///
/// Brushed aluminium, black text on light metal, amber dial illumination,
/// walnut side cheeks on the window frame. This is the light theme built to
/// find every dark-mode assumption left in the codebase — no bloom (printed
/// labels), a needle meter with a cream face, raised knobs with black
/// indicator lines.
public struct SilverFace: Theme {
    public let id = "silverFace"
    public let displayName = "SilverFace"

    public init() {}

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(red: 0.78, green: 0.78, blue: 0.785),
            panelBackground: Color(red: 0.81, green: 0.81, blue: 0.815),
            panelBorder: Color(red: 0.52, green: 0.52, blue: 0.53),

            // Printed, not glass — no background box is actually drawn
            // (`displayStyle` is `.printed`), but the value it holds still
            // matters for anything that reads it before checking the style.
            readoutBackground: Color(red: 0.81, green: 0.81, blue: 0.815),
            // A burnt, ink-dark amber rather than a bright glowing one — a
            // printed dial has no backlight to be bright *with*, so what
            // reads as "amber" here has to carry the whole way on pigment,
            // and at 3:1 against this panel (its size clears WCAG's large-
            // text bar) a brighter amber does not.
            readoutForeground: Color(red: 0.35, green: 0.20, blue: 0.03),
            readoutDim: Color(red: 0.62, green: 0.62, blue: 0.63),

            meterNominal: Color(red: 0.16, green: 0.16, blue: 0.17),
            meterHot: Color(red: 0.72, green: 0.16, blue: 0.10),
            meterHold: Color(red: 0.35, green: 0.20, blue: 0.03),

            controlActive: Color(red: 0.35, green: 0.20, blue: 0.03),
            // Darker than a mid grey would need to be against a dark panel:
            // this is what a *disabled* control is drawn in, and against a
            // panel this light the obvious mid grey measured 2.4:1 — a
            // disabled fader that had faded out of visibility rather than
            // reading as deliberately unavailable.
            controlIdle: Color(red: 0.42, green: 0.42, blue: 0.43),
            controlTrack: Color(red: 0.68, green: 0.68, blue: 0.685),

            // Black text on light metal — literally.
            labelPrimary: Color(red: 0.12, green: 0.12, blue: 0.13),
            // Darker than a secondary tone would need to be against a dark
            // panel: this background is already light, so there is very
            // little headroom left before a lighter grey stops clearing
            // 3:1 against it at all, small as this text is.
            labelSecondary: Color(red: 0.24, green: 0.24, blue: 0.25),

            meterFace: Color(red: 0.93, green: 0.89, blue: 0.79),
            meterScale: Color(red: 0.22, green: 0.18, blue: 0.12),
            meterNeedle: Color(red: 0.10, green: 0.10, blue: 0.10),
            meterZoneWarning: Color(red: 0.72, green: 0.16, blue: 0.10),

            // Unused while `displayStyle` is `.printed` — paired with a zero
            // `displayGlowRadius` below.
            displayGlow: Color(red: 0.62, green: 0.38, blue: 0.05),

            knobFace: Color(red: 0.83, green: 0.83, blue: 0.84),
            knobIndicator: Color(red: 0.10, green: 0.10, blue: 0.10),
            knobArc: Color(red: 0.62, green: 0.38, blue: 0.05),
            knobRing: Color(red: 0.48, green: 0.48, blue: 0.49),

            // Moulded caps, a shade darker than the brushed sheet behind
            // them — a different material, not a milled part of the panel.
            buttonFace: Color(red: 0.71, green: 0.71, blue: 0.715),

            // Brushed aluminium's own highlight and shadow — a bright glint
            // and a soft, moderate grey rather than a dark theme's near-black,
            // which would read as a smudge on a panel this light.
            panelHighlight: Color(red: 0.94, green: 0.94, blue: 0.945),
            panelShadow: Color(red: 0.46, green: 0.46, blue: 0.47),

            // Walnut, for the side cheeks — the one place this theme is
            // warm rather than cool metal.
            accentWarm: Color(red: 0.42, green: 0.27, blue: 0.16),
            accentCool: Color(red: 0.40, green: 0.48, blue: 0.55)
        )
    }

    public var typography: ThemeTypography {
        let display = Font.system(size: 19, weight: .regular, design: .monospaced)
        let label = Font.system(size: 11, weight: .regular)
        let brand = Font.system(size: 11, weight: .semibold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 10, weight: .regular),
            readout: display,
            readoutUnit: .system(size: 10, weight: .regular),
            label: label,
            caption: .system(size: 9, weight: .regular),
            displayFace: display,
            labelFace: label,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 12,
            panelSpacing: 9,
            controlSpacing: 10,
            tightSpacing: 5,
            faderTrackWidth: 5,
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 10,
            meterWidth: 132,
            knobDiameter: 48,
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
            panelStyle: .separated,
            displayStyle: .printed,
            cornerRadius: 2,
            borderWidth: 1,
            showsCentreDetent: true,
            isLight: true,
            knobStyle: .raised,
            buttonStyle: .raised,
            // Flat, despite the chassis being physical. A brushed aluminium
            // faceplate *is* flat — it is one milled sheet, and the light it
            // catches runs along the grain rather than pooling at the edges.
            // Drawing it `.raised` gave every panel a diagonal gradient
            // stroke and a mid-grey drop shadow, which on a ground this light
            // reads as a smudge under each box rather than as relief. The
            // dimension in this look belongs to the knobs and the buttons,
            // which are genuinely separate objects sitting on that sheet.
            panelRelief: .flat,
            usesSideCheeks: true,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer
    //
    // The first of the older themes with a genuine surface: a brushed
    // aluminium faceplate, grain running horizontally the way a milled sheet
    // is finished. Walnut cheeks now come through `hardware` rather than
    // being assembled from `accentWarm` by the screen.

    public var panelMaterial: ThemeMaterial {
        .brushedMetal(
            base: Color(red: 0.81, green: 0.81, blue: 0.815),
            axis: .horizontal, grainScale: 1.4, grainOpacity: 0.10
        )
    }
    public var windowMaterial: ThemeMaterial {
        .brushedMetal(
            base: Color(red: 0.78, green: 0.78, blue: 0.785),
            axis: .horizontal, grainScale: 1.4, grainOpacity: 0.07
        )
    }
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.62, ambient: 0.55, specular: 0.45)
    }
    public var panelBevel: ThemeBevel { .none }
    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .rounded, highlightOpacity: 0.55, shadowOpacity: 0.45)
    }
    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.6, shadowOpacity: 0.45)
    }
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .inset, highlightOpacity: 0.5, shadowOpacity: 0.4)
    }
    public var knobMaterial: ThemeMaterial {
        .anodised(base: Color(red: 0.83, green: 0.83, blue: 0.84), grainOpacity: 0.08)
    }
    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.71, green: 0.71, blue: 0.715))
    }
    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.93, green: 0.89, blue: 0.79))
    }
    public var meterGlass: ThemeMaterial? {
        .glass(tint: Color(red: 1, green: 1, blue: 1).opacity(0.02), reflection: 0.16, curvature: 0.5)
    }
    public var engraving: ThemeEngraving { .engraved }
    public var hardware: ThemeHardware {
        ThemeHardware(
            sideCheeks: .wood(
                .wood(tone: Color(red: 0.42, green: 0.27, blue: 0.16), grainScale: 26, figure: 0.35)
            )
        )
    }

}

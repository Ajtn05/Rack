import SwiftUI

/// Japanese premium — warmer and softer than `SilverFace`.
///
/// A cream faceplate with gold-anodised trim, warm amber readouts that
/// actually emit light, and a transitional serif carrying every label —
/// Baskerville, which sits historically between old-style and modern and is
/// the definition of "transitional". Panels are recessed into their
/// surround rather than standing proud of it, the opposite read from
/// `SilverFace`'s bolted-on aluminium.
public struct Champagne: Theme {
    public let id = "champagne"
    public let displayName = "Champagne"

    public init() {}

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: Color(red: 0.94, green: 0.90, blue: 0.80),
            panelBackground: Color(red: 0.96, green: 0.92, blue: 0.83),
            panelBorder: Color(red: 0.70, green: 0.56, blue: 0.28),

            // Dark amber glass — bright enough behind it that the emissive
            // foreground has real headroom to bloom against.
            readoutBackground: Color(red: 0.22, green: 0.13, blue: 0.03),
            readoutForeground: Color(red: 0.95, green: 0.65, blue: 0.20),
            readoutDim: Color(red: 0.32, green: 0.22, blue: 0.10),

            // Deeper than the trim gold: a meter bar has to read against
            // `controlTrack` behind it, and the brighter gold measured 2.1:1
            // there — a bar you have to look for rather than see.
            meterNominal: Color(red: 0.56, green: 0.36, blue: 0.09),
            meterHot: Color(red: 0.75, green: 0.20, blue: 0.12),
            // The trim gold, darkened by a quarter. This is also
            // `LevelMeter`'s peak flash against the pale `controlTrack`
            // below, and separately `SpectrumBars`' peak flash against the
            // dark amber glass — the straight trim gold read fine on the
            // glass (5.3:1) but only 1.8:1 on the light track. This darker
            // cut is the one point in the range that clears both at once,
            // which only exists here because `controlTrack` is bright
            // enough (not blazing, unlike `TapeMachine`'s) to still leave a
            // gold-toned value some room below it.
            meterHold: Color(red: 0.54, green: 0.435, blue: 0.225),

            // A dark bronze, not the brighter trim gold below — this sits
            // behind a selected chip's reversed cream text, and the
            // brighter gold does not clear that text at 3:1 the way this
            // does.
            controlActive: Color(red: 0.32, green: 0.22, blue: 0.06),
            controlIdle: Color(red: 0.55, green: 0.48, blue: 0.40),
            controlTrack: Color(red: 0.86, green: 0.80, blue: 0.66),

            // Warm dark brown rather than true black — softer, the way the
            // whole theme is softer than `SilverFace`.
            labelPrimary: Color(red: 0.20, green: 0.14, blue: 0.08),
            labelSecondary: Color(red: 0.30, green: 0.25, blue: 0.18),

            meterFace: Color(red: 0.95, green: 0.90, blue: 0.78),
            meterScale: Color(red: 0.28, green: 0.20, blue: 0.12),
            meterNeedle: Color(red: 0.18, green: 0.13, blue: 0.08),
            meterZoneWarning: Color(red: 0.75, green: 0.20, blue: 0.12),

            // The readout's own colour — a bloom is more of that light, not
            // a different one.
            displayGlow: Color(red: 0.95, green: 0.65, blue: 0.20),

            knobFace: Color(red: 0.92, green: 0.87, blue: 0.75),
            knobIndicator: Color(red: 0.20, green: 0.14, blue: 0.08),
            // Brighter than `controlActive` — nothing reverses text over an
            // arc or a bezel, so nothing forces the darker shade.
            knobArc: Color(red: 0.70, green: 0.56, blue: 0.28),
            // The gold bezel, literally.
            knobRing: Color(red: 0.72, green: 0.58, blue: 0.30),

            // Cream caps on a cream faceplate, separated by their gold
            // bezel rather than by a change of colour.
            buttonFace: Color(red: 0.90, green: 0.85, blue: 0.72),

            panelHighlight: Color(red: 0.99, green: 0.965, blue: 0.90),
            // Warm brown rather than a dark theme's near-black — softer,
            // matching this theme's own description of itself.
            panelShadow: Color(red: 0.55, green: 0.46, blue: 0.32),

            // One warm palette rather than two — "warmer and softer" reads
            // as *less* contrast between hands, not more, so both aliases
            // point at the same trim gold.
            accentWarm: Color(red: 0.70, green: 0.56, blue: 0.28),
            accentCool: Color(red: 0.70, green: 0.56, blue: 0.28),

            // The spectrum's own lit colour. `meterNominal` above is
            // calibrated against the pale `controlTrack` a fader runs in;
            // the spectrum draws directly on the dark amber display glass
            // instead, where that same gold measured 2.66:1 — present, but
            // not the "warmer and softer" theme's readout glowing the way
            // its numerals do. A brighter cut of the same gold, so the bars
            // read as part of the display rather than as a panel meter that
            // wandered onto it.
            readoutLevel: Color(red: 0.90, green: 0.62, blue: 0.24)
        )
    }

    public var typography: ThemeTypography {
        // Georgia, not Baskerville. Baskerville is the more literally
        // "transitional" of the two and it looked wrong on sight: it is a
        // *print* face, cut with fine hairlines and a small x-height, and
        // at the 9–12pt a control legend actually gets those hairlines
        // drop below what the display can resolve — the strokes break up
        // and the whole panel reads as blurry rather than as elegant.
        //
        // Georgia was drawn for screens from the start, by a punchcutter
        // working in the same transitional tradition: sturdy stems, a
        // large x-height, and figures that hold their shape at caption
        // size. It keeps the warm, slightly formal voice this theme wants
        // and is legible at the sizes this interface has, which the more
        // historically correct answer was not.
        func georgia(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .custom("Georgia", size: size).weight(weight)
        }

        // The one place this theme is not serif: numerals in a clean
        // tabular face, which a transitional serif was never cut to set
        // well, paired against label text in the serif it was.
        //
        // 16.5, not the 19 this started at. Georgia's large x-height makes
        // the labels around it read bigger than their nominal size, and a
        // nineteen-point figure beside a ten-and-a-half-point legend was far
        // enough out of proportion that the readouts stopped looking like
        // part of the same panel.
        let display = Font.system(size: 16.5, weight: .medium, design: .monospaced)
        // A point smaller than the Baskerville sizes they replace —
        // Georgia's larger x-height means it reads bigger at the same
        // nominal size, so matching the old *apparent* size means asking
        // for slightly less.
        let label = georgia(10.5)
        let brand = georgia(11, weight: .bold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: georgia(9.5),
            readout: display,
            readoutUnit: georgia(9.5),
            label: label,
            caption: georgia(9),
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
            faderHeight: 112,
            faderCapHeight: 14,
            meterHeight: 10,
            meterWidth: 132,
            knobDiameter: 48,
            readoutMinWidth: 62,
            graphHeight: 104,
            traceWidth: 2,
            chipMinWidth: 60,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 122,
            // Real bloom, softer than `BlueMeter`'s — a warm readout glowing
            // gently rather than a cold one blazing.
            displayGlowRadius: 3
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .emissive,
            cornerRadius: 7,
            borderWidth: 1.5,
            showsCentreDetent: true,
            isLight: true,
            knobStyle: .raised,
            buttonStyle: .raised,
            panelRelief: .inset,
            usesSideCheeks: false,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer
    //
    // Cream enamel over a steel faceplate, gold trim, and readouts set behind
    // glass. Softer light than `BlueMeter` — more ambient, less specular —
    // which is most of what makes this theme read as warmer.

    public var panelMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.96, green: 0.92, blue: 0.83), gloss: 0.10)
    }
    public var windowMaterial: ThemeMaterial {
        .flat(Color(red: 0.94, green: 0.90, blue: 0.80))
    }
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.7, ambient: 0.65, specular: 0.35)
    }
    public var panelBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .inset, highlightOpacity: 0.5, shadowOpacity: 0.3)
    }
    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .rounded, highlightOpacity: 0.55, shadowOpacity: 0.35)
    }
    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.55, shadowOpacity: 0.35)
    }
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.45, shadowOpacity: 0.45)
    }
    public var knobMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.92, green: 0.87, blue: 0.75), gloss: 0.12)
    }
    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.90, green: 0.85, blue: 0.72))
    }
    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.95, green: 0.90, blue: 0.78))
    }
    public var meterGlass: ThemeMaterial? {
        .glass(tint: Color(red: 1, green: 1, blue: 1).opacity(0.02), reflection: 0.14, curvature: 0.55)
    }
    public var engraving: ThemeEngraving { .engraved }
    public var hardware: ThemeHardware { .none }

}

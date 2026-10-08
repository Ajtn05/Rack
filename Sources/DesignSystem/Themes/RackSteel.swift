import SwiftUI

/// Industrial rack hardware: brushed aluminium, engraved black lettering, and
/// ears bolted to a 19-inch frame.
///
/// The least decorated of the skeuomorphic set, and deliberately so. Its whole
/// character is one honest material — a milled aluminium sheet with the grain
/// running horizontally — plus type cut into it and the ironmongery that holds
/// it in the rack. Nothing is glossy, nothing is warm except the meter
/// backlight, and there is no ornament that a real 2U faceplate would not
/// have.
///
/// It is also the light theme of the group, which makes it the one that finds
/// dark-mode assumptions: every shadow has to work against a bright ground,
/// and every piece of type is dark-on-light rather than the reverse.
public struct RackSteel: Theme {
    public let id = "rackSteel"
    public let displayName = "RackSteel"

    public init() {}

    // The panel's own aluminium, named once so the material and the colour
    // token cannot drift apart.
    private var aluminium: Color { Color(red: 0.72, green: 0.725, blue: 0.735) }
    private var aluminiumDark: Color { Color(red: 0.65, green: 0.655, blue: 0.665) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: aluminiumDark,
            panelBackground: aluminium,
            // The machined edge between one faceplate and the next.
            panelBorder: Color(red: 0.46, green: 0.465, blue: 0.475),

            // Display windows are set into the panel and are genuinely dark
            // behind their glass — the one place this theme goes black.
            readoutBackground: Color(red: 0.10, green: 0.10, blue: 0.105),
            // Warm amber backlight behind the glass, which is what a lamp
            // behind a panel window actually looks like.
            readoutForeground: Color(red: 1.0, green: 0.72, blue: 0.32),
            // Brightened off a straight dark-amber-on-black extrapolation:
            // that read as barely above the glass itself (1.4:1) — the
            // spectrum's unlit groove all but vanished into its own
            // background, which is most of why the whole display looked
            // faint rather than empty-but-legible.
            readoutDim: Color(red: 0.36, green: 0.28, blue: 0.17),

            // Dark bars on a light panel: the *fader-mounted* meters (the EQ
            // band fills, `LevelSlider`, `LevelMeter`'s channel bars) read as
            // ink against the light aluminium groove, not as light, because
            // nothing there is emissive.
            meterNominal: Color(red: 0.20, green: 0.21, blue: 0.22),
            meterHot: Color(red: 0.62, green: 0.13, blue: 0.09),
            // Also used as the spectrum's peak marker (see `readoutLevel`
            // below), which is why this is a warm near-white rather than the
            // amber the rest of the theme runs on: it has to read against
            // both the light groove (needs real brightness) and the near-
            // black display glass (anything clears that), and only the
            // bright end of that range does both. A near-white peak flash is
            // also just what a peak marker is on real gear, dial colour
            // notwithstanding.
            meterHold: Color(red: 1.0, green: 0.98, blue: 0.92),

            // Engaged is the amber the lamps and the meter backlight use.
            // Dark enough to carry the panel's own label colour reversed on
            // it, which is checked in the contrast audit rather than assumed.
            controlActive: Color(red: 0.42, green: 0.26, blue: 0.03),
            // Disabled has very little room on a ground this bright before it
            // stops being visible at all — measured, not guessed. The obvious
            // mid grey came out at 2.7:1 against the faceplate.
            controlIdle: Color(red: 0.36, green: 0.365, blue: 0.375),
            controlTrack: Color(red: 0.56, green: 0.565, blue: 0.575),

            // Engraved black lettering, filled with paint.
            labelPrimary: Color(red: 0.11, green: 0.11, blue: 0.12),
            labelSecondary: Color(red: 0.24, green: 0.245, blue: 0.25),

            // Tan VU faces, backlit warm. Darker than a cream face because
            // the amber lamp behind it lifts it in practice.
            meterFace: Color(red: 0.80, green: 0.68, blue: 0.46),
            meterScale: Color(red: 0.14, green: 0.11, blue: 0.07),
            meterNeedle: Color(red: 0.10, green: 0.09, blue: 0.08),
            // Deeper than a signal red would normally be. This is *printed
            // ink on the meter card*, not a lit bar — it has to clear 4.5:1
            // against a tan face as small scale markings, and the brighter
            // red measured 3.7:1 there.
            meterZoneWarning: Color(red: 0.48, green: 0.10, blue: 0.07),

            displayGlow: Color(red: 1.0, green: 0.72, blue: 0.32),

            // Black machined caps with white indicator lines — the classic
            // instrument knob, and the strongest contrast on the panel.
            knobFace: Color(red: 0.15, green: 0.15, blue: 0.16),
            knobIndicator: Color(red: 0.95, green: 0.95, blue: 0.95),
            knobArc: Color(red: 0.42, green: 0.26, blue: 0.03),
            knobRing: Color(red: 0.38, green: 0.385, blue: 0.395),

            // Caps a shade darker than the faceplate — a separate moulded
            // part, not a milled area of the same sheet.
            buttonFace: Color(red: 0.63, green: 0.635, blue: 0.645),

            // Aluminium's own glint and the shadow in a machined edge. The
            // shadow is a mid grey rather than near-black: on a panel this
            // bright, a black shadow reads as a smudge.
            panelHighlight: Color(red: 0.93, green: 0.935, blue: 0.945),
            panelShadow: Color(red: 0.38, green: 0.385, blue: 0.395),

            accentWarm: Color(red: 0.42, green: 0.26, blue: 0.03),
            accentCool: Color(red: 0.42, green: 0.43, blue: 0.45),

            // The spectrum's own lit colour, distinct from `meterNominal`.
            //
            // This is the theme the override exists for: the aluminium
            // groove `meterNominal` is tuned against is light, the spectrum's
            // display glass is near-black, and those are opposite enough
            // ends of the scale that one colour cannot read well against
            // both — an amber bright enough to be vibrant on the glass
            // measures barely above 1:1 on the groove. A vibrant amber here,
            // matching the display's own backlight rather than the panel's
            // ink-on-aluminium meters.
            readoutLevel: Color(red: 0.92, green: 0.62, blue: 0.22)
        )
    }

    public var typography: ThemeTypography {
        // A plain grotesque, the way panel legends are actually set — this is
        // engraving-filled lettering, not a typeface with a personality.
        let display = Font.system(size: 18, weight: .medium, design: .monospaced)
        // One legend face for everything cut into the panel — readout
        // captions and button/chip legends alike. They used to differ (the
        // button face ran a half-point larger and a weight heavier), which
        // read as two different hands lettering the same faceplate; a real
        // engraved panel is cut with one tool throughout.
        let caption = Font.system(size: 9, weight: .regular)
        let brand = Font.system(size: 10.5, weight: .bold)

        return ThemeTypography(
            unitTitle: brand,
            unitStatus: .system(size: 9.5, weight: .regular),
            readout: display,
            readoutUnit: .system(size: 9.5, weight: .regular),
            label: caption,
            caption: caption,
            displayFace: display,
            labelFace: caption,
            brandFace: brand
        )
    }

    public var metrics: ThemeMetrics {
        ThemeMetrics(
            panelPadding: 13,
            panelSpacing: 6,
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
            chipMinWidth: 58,
            windowTopInset: 28,
            iconSize: 18,
            appNameWidth: 120,
            // The display windows are backlit, and a lamp behind a panel
            // window does bloom a little through the glass.
            displayGlowRadius: 2.5
        )
    }

    public var chrome: ThemeChrome {
        ThemeChrome(
            panelStyle: .separated,
            displayStyle: .emissive,
            // Machined, not moulded: a faceplate corner is very nearly square.
            cornerRadius: 2,
            borderWidth: 1,
            showsCentreDetent: true,
            isLight: true,
            knobStyle: .raised,
            knobIndicatorStyle: .line,
            buttonStyle: .raised,
            panelRelief: .flat,
            usesSideCheeks: false,
            meterStyle: .needle
        )
    }

    // MARK: - Material layer

    /// Horizontal grain, which is how a rack faceplate is actually finished —
    /// the brush runs the long axis of the sheet.
    public var panelMaterial: ThemeMaterial {
        .brushedMetal(base: aluminium, axis: .horizontal, grainScale: 1.3, grainOpacity: 0.12)
    }

    public var windowMaterial: ThemeMaterial {
        .brushedMetal(base: aluminiumDark, axis: .horizontal, grainScale: 1.3, grainOpacity: 0.09)
    }

    /// Slightly lower elevation than the standard light, which lengthens
    /// every shadow a little — an instrument rack is lit from above and in
    /// front, and the shadows under its hardware are visible rather than
    /// tucked underneath.
    public var lighting: ThemeLighting {
        ThemeLighting(angle: .degrees(315), elevation: 0.55, ambient: 0.5, specular: 0.5)
    }

    /// Faceplates are flat sheets. The relief in this theme belongs to the
    /// parts bolted *to* them — knobs, caps, screws, and the recessed
    /// display windows.
    public var panelBevel: ThemeBevel { .none }

    public var knobBevel: ThemeBevel {
        ThemeBevel(width: 2.5, style: .rounded, highlightOpacity: 0.4, shadowOpacity: 0.5)
    }

    public var buttonBevel: ThemeBevel {
        ThemeBevel(width: 1.5, style: .raised, highlightOpacity: 0.6, shadowOpacity: 0.45)
    }

    /// Display windows are cut into the panel, so their bevel is inset and
    /// noticeably deeper than anything else here.
    public var displayBevel: ThemeBevel {
        ThemeBevel(width: 2, style: .inset, highlightOpacity: 0.55, shadowOpacity: 0.5)
    }

    /// Machined black caps: anodised rather than painted, with a fine even
    /// grain that only shows at the rim.
    public var knobMaterial: ThemeMaterial {
        .anodised(base: Color(red: 0.15, green: 0.15, blue: 0.16), grainOpacity: 0.10)
    }

    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.63, green: 0.635, blue: 0.645))
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.80, green: 0.68, blue: 0.46))
    }

    /// Glass over the meter, kept weak — the printed scale underneath has to
    /// stay readable through it, and a reflection that obscures the thing it
    /// is protecting is a worse lie than no reflection.
    public var meterGlass: ThemeMaterial? {
        .glass(
            tint: Color(red: 1, green: 1, blue: 1).opacity(0.015),
            reflection: 0.14, curvature: 0.4
        )
    }

    /// Cut into the aluminium and filled with black paint — which is what
    /// "engraved black lettering" physically is, and why it gets `.etched`
    /// rather than `.engraved`.
    public var engraving: ThemeEngraving {
        .etched(fill: Color(red: 0.11, green: 0.11, blue: 0.12))
    }

    /// Bolted down, but not flanged.
    ///
    /// The screws stay — they are on the faceplates themselves and are most
    /// of what says this is instrument hardware. The 19-inch ears are off:
    /// they cost two vertical strips of window width on every screen size,
    /// and at the widths this interface actually gets used at that is room
    /// the panels want more than the frame does.
    ///
    /// `rackEars` remains in `ThemeHardware` and works — this is a decision
    /// about *this* theme, not a removed capability.
    public var hardware: ThemeHardware {
        ThemeHardware(screws: .phillips, rackEars: false)
    }
}

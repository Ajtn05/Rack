import SwiftUI

/// `RackSteel` in black anodised aluminium.
///
/// Not a recolour for its own sake: black anodising is what most rack
/// hardware is actually finished in, and it is arguably the more common
/// version of this look than the brushed silver one. The grain still runs
/// horizontally because the sheet is still brushed before it is anodised —
/// the dye goes into the surface, it does not hide the machining.
///
/// Lettering flips from black-filled to white-filled, which is the real
/// difference: on a black panel the engraving is filled with light paint, and
/// that is the only reason the type reads at all.
///
/// Structure delegates to `RackSteel`, so the pair cannot drift.
public struct RackSteelDark: Theme {
    public let id = "rackSteelDark"
    public let displayName = "RackSteel Dark"

    public init() {}

    private let light = RackSteel()

    private var anodised: Color { Color(red: 0.20, green: 0.205, blue: 0.215) }
    private var anodisedDeep: Color { Color(red: 0.14, green: 0.145, blue: 0.155) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: anodisedDeep,
            panelBackground: anodised,
            panelBorder: Color(red: 0.40, green: 0.405, blue: 0.42),

            // Display windows go *darker* than the panel even here — a lit
            // window has to be a hole in the surface, not a patch of it.
            readoutBackground: Color(red: 0.07, green: 0.07, blue: 0.075),
            readoutForeground: Color(red: 1.0, green: 0.72, blue: 0.32),
            readoutDim: Color(red: 0.26, green: 0.20, blue: 0.12),

            // Light bars on a dark panel — the inverse of the light theme's
            // ink-on-metal, and for the same reason: a meter should read as
            // the opposite of its ground.
            meterNominal: Color(red: 0.80, green: 0.81, blue: 0.83),
            meterHot: Color(red: 0.90, green: 0.28, blue: 0.20),
            meterHold: Color(red: 0.95, green: 0.74, blue: 0.36),

            // Lamp-bright amber. The light theme's deep amber was chosen when
            // `controlActive` still had to carry reversed text; it no longer
            // does, and on a dark panel a dark lamp is invisible anyway.
            controlActive: Color(red: 1.0, green: 0.74, blue: 0.34),
            controlIdle: Color(red: 0.52, green: 0.525, blue: 0.535),
            controlTrack: Color(red: 0.12, green: 0.125, blue: 0.135),

            // White-filled engraving.
            labelPrimary: Color(red: 0.93, green: 0.935, blue: 0.94),
            labelSecondary: Color(red: 0.76, green: 0.765, blue: 0.78),

            // The tan VU card stays. A meter face is a printed card lit from
            // behind, and it does not change colour because the chassis
            // around it was anodised black.
            meterFace: Color(red: 0.80, green: 0.68, blue: 0.46),
            meterScale: Color(red: 0.14, green: 0.11, blue: 0.07),
            meterNeedle: Color(red: 0.10, green: 0.09, blue: 0.08),
            meterZoneWarning: Color(red: 0.48, green: 0.10, blue: 0.07),

            displayGlow: Color(red: 1.0, green: 0.72, blue: 0.32),

            // Black caps on a black panel would vanish, so these come *up*
            // rather than down — a machined aluminium cap left undyed.
            knobFace: Color(red: 0.42, green: 0.425, blue: 0.435),
            knobIndicator: Color(red: 0.97, green: 0.97, blue: 0.97),
            knobArc: Color(red: 1.0, green: 0.74, blue: 0.34),
            knobRing: Color(red: 0.60, green: 0.605, blue: 0.62),

            buttonFace: Color(red: 0.28, green: 0.285, blue: 0.295),

            panelHighlight: Color(red: 0.48, green: 0.485, blue: 0.50),
            panelShadow: Color(red: 0.04, green: 0.04, blue: 0.045),

            accentWarm: Color(red: 1.0, green: 0.74, blue: 0.34),
            accentCool: Color(red: 0.55, green: 0.56, blue: 0.58)
        )
    }

    public var typography: ThemeTypography { light.typography }
    public var metrics: ThemeMetrics { light.metrics }

    public var chrome: ThemeChrome {
        var chrome = light.chrome
        chrome.isLight = false
        return chrome
    }

    // MARK: - Material layer

    /// Still brushed, still horizontal — anodising dyes the surface, it does
    /// not fill the machining in.
    public var panelMaterial: ThemeMaterial {
        .brushedMetal(base: anodised, axis: .horizontal, grainScale: 1.3, grainOpacity: 0.14)
    }

    public var windowMaterial: ThemeMaterial {
        .brushedMetal(base: anodisedDeep, axis: .horizontal, grainScale: 1.3, grainOpacity: 0.10)
    }

    public var lighting: ThemeLighting { light.lighting }
    public var panelBevel: ThemeBevel { light.panelBevel }
    public var knobBevel: ThemeBevel { light.knobBevel }
    public var buttonBevel: ThemeBevel { light.buttonBevel }
    public var displayBevel: ThemeBevel { light.displayBevel }

    public var knobMaterial: ThemeMaterial {
        .anodised(base: Color(red: 0.42, green: 0.425, blue: 0.435), grainOpacity: 0.10)
    }

    public var buttonMaterial: ThemeMaterial {
        .flat(Color(red: 0.28, green: 0.285, blue: 0.295))
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.80, green: 0.68, blue: 0.46))
    }

    public var meterGlass: ThemeMaterial? { light.meterGlass }

    /// Cut into the anodising and filled with white paint — the inverse of
    /// the light theme, and the whole reason the type reads.
    public var engraving: ThemeEngraving {
        .etched(fill: Color(red: 0.93, green: 0.935, blue: 0.94))
    }

    public var hardware: ThemeHardware { light.hardware }
}

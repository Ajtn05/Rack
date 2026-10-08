import SwiftUI

/// `TapeMachine` in the charcoal the later machines were finished in.
///
/// The seafoam era gave way to dark grey once studio furniture stopped being
/// painted to match the room, and the cream meter faces stayed exactly as they
/// were — which is the detail worth keeping, because a lit cream card on a
/// charcoal chassis is the single most recognisable thing about a machine of
/// that generation.
///
/// Structure delegates to `TapeMachine`, including its inset transport
/// buttons: a cap that sits down in a recess does not change how it is
/// mounted because the paint changed.
public struct TapeMachineDark: Theme {
    public let id = "tapeMachineDark"
    public let displayName = "TapeMachine Dark"

    public init() {}

    private let light = TapeMachine()

    private var charcoal: Color { Color(red: 0.235, green: 0.245, blue: 0.245) }
    private var charcoalDeep: Color { Color(red: 0.165, green: 0.175, blue: 0.175) }

    public var colors: ThemeColors {
        ThemeColors(
            windowBackground: charcoalDeep,
            panelBackground: charcoal,
            panelBorder: Color(red: 0.44, green: 0.46, blue: 0.46),

            readoutBackground: Color(red: 0.07, green: 0.065, blue: 0.065),
            readoutForeground: Color(red: 1.0, green: 0.34, blue: 0.26),
            // Neutral rather than red-tinted: this also draws the *unlit*
            // portion of a spectrum bar, and a red one there reads as a hot
            // signal rather than as empty scale.
            readoutDim: Color(red: 0.17, green: 0.16, blue: 0.16),

            meterNominal: Color(red: 0.82, green: 0.84, blue: 0.84),
            meterHot: Color(red: 0.88, green: 0.24, blue: 0.16),
            meterHold: Color(red: 0.90, green: 0.72, blue: 0.34),

            // Transport red, lit. On a charcoal panel the light theme's deep
            // red would read as a dark smudge rather than as a lamp.
            controlActive: Color(red: 1.0, green: 0.30, blue: 0.22),
            controlIdle: Color(red: 0.52, green: 0.54, blue: 0.54),
            controlTrack: Color(red: 0.15, green: 0.16, blue: 0.16),

            labelPrimary: Color(red: 0.93, green: 0.94, blue: 0.94),
            labelSecondary: Color(red: 0.76, green: 0.78, blue: 0.78),

            // Unchanged from the light theme, and deliberately: the meter is
            // a lit card in its own housing, not part of the paintwork.
            meterFace: Color(red: 0.92, green: 0.89, blue: 0.81),
            meterScale: Color(red: 0.11, green: 0.10, blue: 0.09),
            meterNeedle: Color(red: 0.72, green: 0.13, blue: 0.10),
            meterZoneWarning: Color(red: 0.58, green: 0.10, blue: 0.07),

            displayGlow: Color(red: 1.0, green: 0.34, blue: 0.26),

            // The cream transport caps stay cream — they are moulded parts,
            // not painted chassis, and on a dark machine they stand out
            // exactly the way they are meant to.
            knobFace: Color(red: 0.84, green: 0.83, blue: 0.79),
            knobIndicator: Color(red: 0.10, green: 0.11, blue: 0.11),
            knobArc: Color(red: 1.0, green: 0.30, blue: 0.22),
            knobRing: Color(red: 0.56, green: 0.58, blue: 0.58),

            buttonFace: Color(red: 0.33, green: 0.345, blue: 0.345),

            panelHighlight: Color(red: 0.50, green: 0.52, blue: 0.52),
            panelShadow: Color(red: 0.05, green: 0.055, blue: 0.055),

            accentWarm: Color(red: 1.0, green: 0.30, blue: 0.22),
            accentCool: Color(red: 0.56, green: 0.58, blue: 0.58)
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

    /// Still baked enamel, just a darker batch of it.
    public var panelMaterial: ThemeMaterial {
        .enamel(base: charcoal, gloss: 0.13)
    }

    public var windowMaterial: ThemeMaterial {
        .enamel(base: charcoalDeep, gloss: 0.09)
    }

    public var lighting: ThemeLighting { light.lighting }
    public var panelBevel: ThemeBevel { light.panelBevel }
    public var knobBevel: ThemeBevel { light.knobBevel }
    /// Inherited, and worth noting it survives the recolour: these are still
    /// `.inset`, because a transport cap still sits down in a recess.
    public var buttonBevel: ThemeBevel { light.buttonBevel }
    public var displayBevel: ThemeBevel { light.displayBevel }

    public var knobMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.84, green: 0.83, blue: 0.79), gloss: 0.12)
    }

    public var buttonMaterial: ThemeMaterial {
        .enamel(base: Color(red: 0.33, green: 0.345, blue: 0.345), gloss: 0.10)
    }

    public var meterFaceMaterial: ThemeMaterial {
        .flat(Color(red: 0.92, green: 0.89, blue: 0.81))
    }

    public var meterGlass: ThemeMaterial? { light.meterGlass }

    /// Screened on, as on the light machine — but in white, which is what a
    /// dark chassis is actually lettered with.
    public var engraving: ThemeEngraving { .silkscreen }

    public var hardware: ThemeHardware { light.hardware }
}

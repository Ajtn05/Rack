import SwiftUI

/// A skin.
///
/// Everything Rack draws reads its appearance from one of these, injected
/// through the environment. No view holds a colour, a font, a radius or a
/// spacing value of its own — that is the whole point, and it is enforced at
/// build time by `Scripts/check-boundaries.sh`.
///
/// Adding a theme is one file under `Themes/` and one line in
/// `ThemeRegistry`. See `Themes/README.md`.
public protocol Theme: Sendable {
    /// Stable identifier, used for persistence and selection. Never shown.
    var id: String { get }

    /// What the user sees in a theme picker.
    var displayName: String { get }

    var colors: ThemeColors { get }
    var typography: ThemeTypography { get }
    var metrics: ThemeMetrics { get }
    var chrome: ThemeChrome { get }

    // MARK: - Material layer
    //
    // Unlike the four above, these carry defaults. That is a deliberate
    // difference and worth the sentence: `colors` and the rest describe
    // things every skin must have an opinion about, so a missing one should
    // be a compile error. Materials, lighting and ironmongery describe
    // *optional physicality* — a theme that says nothing about them is flat,
    // unlit and unbolted, which is a coherent thing to be and is exactly
    // what the pre-material themes already were.
    //
    // Every shipped theme still states all of these explicitly, so nothing
    // is special-cased; the defaults exist so a seventh theme can be written
    // without boilerplate it does not care about.

    /// What a rack unit's face is made of.
    var panelMaterial: ThemeMaterial { get }

    /// What the window behind the panels is made of.
    var windowMaterial: ThemeMaterial { get }

    /// The single light source every bevel and shadow in the window derives
    /// from.
    var lighting: ThemeLighting { get }

    /// Edge treatment for a rack unit.
    var panelBevel: ThemeBevel { get }

    /// Edge treatment for a knob cap.
    var knobBevel: ThemeBevel { get }

    /// Edge treatment for a pushbutton cap, at rest. Pressed, it is drawn
    /// `.inverted` — a cap that stands proud goes down, and nothing else
    /// about it changes.
    var buttonBevel: ThemeBevel { get }

    /// Edge treatment for a display window. Almost always `.inset`: a
    /// readout is set *into* a panel.
    var displayBevel: ThemeBevel { get }

    /// What a knob cap is made of.
    var knobMaterial: ThemeMaterial { get }

    /// A second knob cap material, for themes that colour-code by function.
    ///
    /// Console preamps do this as a matter of course — oxblood caps for gain,
    /// blue for equalisation — and it is genuinely informative rather than
    /// decorative: it tells you which group a control belongs to before you
    /// have read its legend. `RotaryControl` takes a `variant` saying which
    /// group a knob is in, and a theme that does not distinguish them returns
    /// nil here and gets one colour everywhere.
    var knobAlternateMaterial: ThemeMaterial? { get }

    /// What a pushbutton cap is made of.
    var buttonMaterial: ThemeMaterial { get }

    /// The lit face behind a needle meter.
    var meterFaceMaterial: ThemeMaterial { get }

    /// The pane over that face, or nil for an unglazed meter.
    var meterGlass: ThemeMaterial? { get }

    /// How panel legends are physically part of the panel.
    var engraving: ThemeEngraving { get }

    /// Optional ironmongery.
    var hardware: ThemeHardware { get }
}

extension Theme {
    public var panelMaterial: ThemeMaterial { .flat(colors.panelBackground) }
    public var windowMaterial: ThemeMaterial { .flat(colors.windowBackground) }
    public var lighting: ThemeLighting { .standard }
    public var panelBevel: ThemeBevel { .none }
    public var knobBevel: ThemeBevel { .none }
    public var buttonBevel: ThemeBevel { .none }
    public var displayBevel: ThemeBevel { .none }
    public var knobMaterial: ThemeMaterial { .flat(colors.knobFace) }
    public var knobAlternateMaterial: ThemeMaterial? { nil }
    public var buttonMaterial: ThemeMaterial { .flat(colors.buttonFace) }
    public var meterFaceMaterial: ThemeMaterial { .flat(colors.meterFace) }
    public var meterGlass: ThemeMaterial? { nil }
    public var engraving: ThemeEngraving { .silkscreen }
    public var hardware: ThemeHardware { .none }
}

// MARK: - Colours

/// Semantic colour roles.
///
/// Every name here describes **what the colour is for**, never what it looks
/// like. A token called `teal` or `darkGray` is a bug: it stops meaning
/// anything the moment a second theme exists, and it drags one skin's
/// decisions into every view that mentions it.
///
/// The full reference, with what draws each one, is in `Themes/README.md`.
public struct ThemeColors: Sendable {
    /// Behind everything.
    public var windowBackground: Color

    /// The face of a rack unit.
    public var panelBackground: Color

    /// The edge of a rack unit. Invisible in themes with no borders.
    public var panelBorder: Color

    /// Behind a numeric display — the glass of a fluorescent readout.
    public var readoutBackground: Color

    /// Lit segments, digits, the value itself.
    public var readoutForeground: Color

    /// Unlit segments and secondary text inside a readout. In a segmented
    /// face this is what draws the ghost digits behind the live ones.
    public var readoutDim: Color

    /// A meter below its warning threshold.
    public var meterNominal: Color

    /// A meter above it.
    public var meterHot: Color

    /// The peak-hold marker.
    public var meterHold: Color

    /// A control that is on, engaged, or away from its default.
    public var controlActive: Color

    /// A control at rest.
    public var controlIdle: Color

    /// The groove a fader or slider runs in.
    public var controlTrack: Color

    /// Titles and values.
    public var labelPrimary: Color

    /// Captions, units, legends.
    public var labelSecondary: Color

    // MARK: - Needle metering
    //
    // A VU or goniometer needle sits on its own small piece of glass, lit
    // independently of the panel around it — these four exist for that,
    // and for nothing else, so a theme with no needle meter yet can still
    // fill them in honestly rather than aliasing them to another role.

    /// The lit face behind a needle meter.
    public var meterFace: Color

    /// The printed scale and tick marks on that face.
    public var meterScale: Color

    /// The needle itself.
    public var meterNeedle: Color

    /// The region of the scale above 0 VU — a needle entering it is entering
    /// warning territory, the same idea `meterHot` is for a bar.
    public var meterZoneWarning: Color

    /// Bloom colour for a readout that emits light. Paired with
    /// `ThemeMetrics.displayGlowRadius`; a theme whose `chrome.displayStyle`
    /// is `.printed` sets that radius to 0 rather than leaving this unset —
    /// there is no "no colour", only "no glow".
    public var displayGlow: Color

    // MARK: - Knobs
    //
    // Distinct from `controlTrack` / `controlActive` / `panelBorder`: those
    // are shared with faders and chips, and a knob that is meant to read as
    // its own physical object — a brass-ringed dial, say — needs colours a
    // fader's groove has no reason to share.

    public var knobFace: Color
    public var knobIndicator: Color
    public var knobArc: Color
    public var knobRing: Color

    /// The face of a pushbutton cap.
    ///
    /// Its own token for the same reason `knobFace` is: a cap is a separate
    /// physical part from the panel behind it and from the grooves
    /// `controlTrack` describes. Reusing `controlTrack` here — which is what
    /// this did first — points a *raised* part at the colour meaning
    /// "recessed", and on a dark theme that produced a cap darker than the
    /// panel it was supposed to be standing on: a hole where a button should
    /// be.
    public var buttonFace: Color

    /// For a panel with physical relief (`chrome.panelRelief`): the edge
    /// catching the light, and the edge falling away from it.
    public var panelHighlight: Color
    public var panelShadow: Color

    /// A second accent, for themes built around two — a warm metal trim
    /// paired with a cool display glow, say. Themes with only one accent
    /// set both to it rather than leaving one an alias with a different name.
    public var accentWarm: Color
    public var accentCool: Color

    /// The lit fill of a bar drawn on the display's own glass — a spectrum
    /// column, specifically — when that needs to differ from `meterNominal`.
    ///
    /// `meterNominal` is calibrated against a panel-mounted meter's groove
    /// (`controlTrack`): `FaderBank`, `LevelSlider` and `LevelMeter` all read
    /// it against that background. `SpectrumBars` reads it against
    /// `readoutBackground` instead, because a spectrum column lives on the
    /// display's own dark glass, not on the panel. On most themes those two
    /// backgrounds sit close enough in brightness that one colour serves
    /// both. `RackSteel` is the exception: a light aluminium groove paired
    /// with genuinely dark VFD glass, opposite ends of the scale — no single
    /// colour clears 3:1 against both, so a value tuned for the groove reads
    /// as barely-there on the glass. Nil means "no exception, use
    /// `meterNominal`," which is every theme but that one.
    public var readoutLevel: Color?

    /// The spectrum's own peak-hold marker, when it needs to differ from
    /// `meterHold`.
    ///
    /// Same reasoning as `readoutLevel`, one token over: `meterHold` is also
    /// `LevelMeter`'s peak flash against `controlTrack`, and on most themes a
    /// single warm-near-white value satisfies both that and
    /// `readoutBackground` at once. `TapeMachine` is the theme where no
    /// single colour can — its `controlTrack` is bright enough that even
    /// white does not clear 3:1 against it, and its `readoutBackground` is
    /// dark enough that only something bright does. Nil means "no
    /// exception, use `meterHold`."
    public var readoutHold: Color?

    public init(
        windowBackground: Color,
        panelBackground: Color,
        panelBorder: Color,
        readoutBackground: Color,
        readoutForeground: Color,
        readoutDim: Color,
        meterNominal: Color,
        meterHot: Color,
        meterHold: Color,
        controlActive: Color,
        controlIdle: Color,
        controlTrack: Color,
        labelPrimary: Color,
        labelSecondary: Color,
        meterFace: Color,
        meterScale: Color,
        meterNeedle: Color,
        meterZoneWarning: Color,
        displayGlow: Color,
        knobFace: Color,
        knobIndicator: Color,
        knobArc: Color,
        knobRing: Color,
        buttonFace: Color,
        panelHighlight: Color,
        panelShadow: Color,
        accentWarm: Color,
        accentCool: Color,
        readoutLevel: Color? = nil,
        readoutHold: Color? = nil
    ) {
        self.windowBackground = windowBackground
        self.panelBackground = panelBackground
        self.panelBorder = panelBorder
        self.readoutBackground = readoutBackground
        self.readoutForeground = readoutForeground
        self.readoutDim = readoutDim
        self.meterNominal = meterNominal
        self.meterHot = meterHot
        self.meterHold = meterHold
        self.controlActive = controlActive
        self.controlIdle = controlIdle
        self.controlTrack = controlTrack
        self.labelPrimary = labelPrimary
        self.labelSecondary = labelSecondary
        self.meterFace = meterFace
        self.meterScale = meterScale
        self.meterNeedle = meterNeedle
        self.meterZoneWarning = meterZoneWarning
        self.displayGlow = displayGlow
        self.knobFace = knobFace
        self.knobIndicator = knobIndicator
        self.knobArc = knobArc
        self.knobRing = knobRing
        self.buttonFace = buttonFace
        self.panelHighlight = panelHighlight
        self.panelShadow = panelShadow
        self.accentWarm = accentWarm
        self.accentCool = accentCool
        self.readoutLevel = readoutLevel
        self.readoutHold = readoutHold
    }
}

// MARK: - Typography

public struct ThemeTypography: Sendable {
    /// The face a rack unit's title is set in.
    public var unitTitle: Font

    /// The status line under a unit title.
    public var unitStatus: Font

    /// Large numbers in a readout.
    public var readout: Font

    /// The unit suffix beside them — "dB", "Hz".
    public var readoutUnit: Font

    /// Control labels.
    public var label: Font

    /// Legends under faders, captions.
    public var caption: Font

    // MARK: - Faces
    //
    // Three separate typographic identities, not one face pressed into every
    // role. `unitTitle`/`unitStatus`/`readout`/`readoutUnit`/`label`/`caption`
    // above are what components actually set; these three are what a theme
    // author builds them *from*, so a serif brand face and a monospaced
    // display face can disagree on purpose rather than by accident. Every
    // shipped theme before this one built all six from a single monospaced
    // family, which is exactly what does not survive a Helvetica-based skin.

    /// What numeric readouts are set in — `readout` and `readoutUnit` are
    /// built from this. Monospaced digits matter more here than anywhere
    /// else: a value that resizes as it counts makes its neighbours twitch.
    public var displayFace: Font

    /// What control labels and captions are set in — `unitStatus`, `label`
    /// and `caption` are built from this.
    public var labelFace: Font

    /// What a unit's title — the panel's own "brand" — is set in.
    /// `unitTitle` is built from this.
    public var brandFace: Font

    public init(
        unitTitle: Font,
        unitStatus: Font,
        readout: Font,
        readoutUnit: Font,
        label: Font,
        caption: Font,
        displayFace: Font,
        labelFace: Font,
        brandFace: Font
    ) {
        self.unitTitle = unitTitle
        self.unitStatus = unitStatus
        self.readout = readout
        self.readoutUnit = readoutUnit
        self.label = label
        self.caption = caption
        self.displayFace = displayFace
        self.labelFace = labelFace
        self.brandFace = brandFace
    }
}

// MARK: - Metrics

/// Sizes and spacing. Anything measured in points.
public struct ThemeMetrics: Sendable {
    public var panelPadding: CGFloat
    public var panelSpacing: CGFloat
    public var controlSpacing: CGFloat
    public var tightSpacing: CGFloat

    public var faderTrackWidth: CGFloat
    public var faderHeight: CGFloat
    public var faderCapHeight: CGFloat

    public var meterHeight: CGFloat

    /// How wide a level meter is drawn.
    ///
    /// A fixed width, because a meter is read by where the bar *is* and that
    /// only means something against a scale that stays put. Stretched to fill
    /// whatever space is going, the same signal lands somewhere different every
    /// time the window is resized.
    public var meterWidth: CGFloat

    public var knobDiameter: CGFloat
    public var readoutMinWidth: CGFloat

    /// The height of a plotted display — the response curve, and the analyzer
    /// that will sit beside it.
    public var graphHeight: CGFloat

    /// The width of a drawn line that carries a value: a curve, a knob's arc.
    /// Distinct from `chrome.borderWidth`, which is structure rather than data,
    /// and which a borderless skin sets to zero.
    public var traceWidth: CGFloat

    /// How large an application icon is drawn in a list.
    public var iconSize: CGFloat

    /// The column an application's name occupies, so the faders beside them
    /// line up rather than starting wherever the longest name happens to end.
    public var appNameWidth: CGFloat

    /// The narrowest a chip is drawn, whatever its legend says. Keeps a row of
    /// buttons looking like a row of buttons.
    public var chipMinWidth: CGFloat

    /// How far the content clears the top of the window.
    ///
    /// A skin that hides the title bar draws under it, and the traffic lights
    /// are still there — so the first panel has to start below them.
    public var windowTopInset: CGFloat

    /// Blur radius for `colors.displayGlow`. Zero for a `.printed` display
    /// style, which has no glow at all — the pairing is what lets a theme
    /// say "no bloom" without a component having to ask `displayStyle` on
    /// top of reading a colour it would then ignore.
    public var displayGlowRadius: CGFloat

    public init(
        panelPadding: CGFloat,
        panelSpacing: CGFloat,
        controlSpacing: CGFloat,
        tightSpacing: CGFloat,
        faderTrackWidth: CGFloat,
        faderHeight: CGFloat,
        faderCapHeight: CGFloat,
        meterHeight: CGFloat,
        meterWidth: CGFloat,
        knobDiameter: CGFloat,
        readoutMinWidth: CGFloat,
        graphHeight: CGFloat,
        traceWidth: CGFloat,
        chipMinWidth: CGFloat,
        windowTopInset: CGFloat,
        iconSize: CGFloat,
        appNameWidth: CGFloat,
        displayGlowRadius: CGFloat
    ) {
        self.panelPadding = panelPadding
        self.panelSpacing = panelSpacing
        self.controlSpacing = controlSpacing
        self.tightSpacing = tightSpacing
        self.faderTrackWidth = faderTrackWidth
        self.faderHeight = faderHeight
        self.faderCapHeight = faderCapHeight
        self.meterHeight = meterHeight
        self.meterWidth = meterWidth
        self.knobDiameter = knobDiameter
        self.readoutMinWidth = readoutMinWidth
        self.graphHeight = graphHeight
        self.traceWidth = traceWidth
        self.chipMinWidth = chipMinWidth
        self.windowTopInset = windowTopInset
        self.iconSize = iconSize
        self.appNameWidth = appNameWidth
        self.displayGlowRadius = displayGlowRadius
    }
}

// MARK: - Chrome

/// The structural choices a skin might want to make differently.
///
/// These are not decoration — they change how a screen is *assembled*, which
/// is why they live in the theme rather than in the views. A skin that draws
/// one continuous surface needs the units to stop drawing their own edges;
/// a skin built from separate boxes needs them to.
public struct ThemeChrome: Sendable {
    public enum PanelStyle: Sendable {
        /// Distinct boxes with their own background and edge — a stack of
        /// components bolted into a rack.
        case separated
        /// One uninterrupted surface; units are grouped by whitespace alone.
        case continuous
    }

    /// How a readout is lit. Supersedes what used to be a plain
    /// segmented-or-not `ReadoutFace` — a printed panel and an emissive one
    /// are both "not segmented" but need to look nothing alike, one with no
    /// glow at all and one with real bloom.
    public enum DisplayStyle: Sendable {
        /// Draws unlit segments behind the value, the way a fluorescent
        /// display shows the digits it is not currently using.
        case segmented
        /// Plain text that emits light — paired with `colors.displayGlow`
        /// and `metrics.displayGlowRadius` for the bloom.
        case emissive
        /// Ink on a panel. No glow, ever — a printed display is not a light
        /// source, and drawing one a bloom regardless is exactly the
        /// dark-display assumption this token exists to stop being implicit.
        case printed
    }

    /// Whether a knob sits flush with the panel or stands proud of it.
    /// `.raised` also gives the knob a machined skirt with tick marks.
    public enum KnobStyle: Sendable {
        case flush
        case raised
    }

    /// What marks a knob's position.
    public enum KnobIndicatorStyle: Sendable {
        /// A painted line running out from the centre.
        case line
        /// A single dot near the rim.
        case dot
        /// A cut into the cap's edge — removed material rather than paint.
        case notch
    }

    /// Whether a pushbutton is drawn as a physical object — standing proud
    /// of the panel at rest, pressed into it when engaged — or as a flat
    /// shape that only changes colour.
    ///
    /// Distinct from `knobStyle` and `panelRelief` because the three are
    /// genuinely independent: `TechnicsTheme` has flat panels and flush
    /// knobs but its buttons are unmistakably physical latching switches,
    /// and `Bauhaus` wants everything flat including these.
    public enum ButtonStyle: Sendable {
        case flat
        case raised
    }

    /// Whether a panel is flat, recessed into its surround, or standing
    /// proud of it — drawn with `colors.panelHighlight` / `panelShadow`.
    public enum PanelRelief: Sendable {
        case flat
        case inset
        case raised
    }

    /// How a level meter is drawn. `.needle` has no consumer yet — the VU
    /// meter it is for is Part 2 — but the token exists now so a theme
    /// already declares which one it wants rather than a component guessing
    /// later.
    public enum MeterStyle: Sendable {
        case bar
        case needle
    }

    public var panelStyle: PanelStyle
    public var displayStyle: DisplayStyle
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat

    /// Whether controls snap visibly to their centre position. A hi-fi fader
    /// has a physical detent at 0; a plain slider does not pretend to.
    public var showsCentreDetent: Bool

    /// Whether this is a light theme. A handful of tokens are already
    /// authored per-theme specifically so components never have to guess at
    /// a colour (`panelHighlight` / `panelShadow` are already the right way
    /// round for whichever theme set them) — this exists for the few places
    /// a *structural* choice, not a colour, reads differently against a
    /// bright panel than a dark one, such as how strong a relief shadow
    /// should be drawn.
    public var isLight: Bool

    public var knobStyle: KnobStyle
    public var knobIndicatorStyle: KnobIndicatorStyle
    public var buttonStyle: ButtonStyle
    public var panelRelief: PanelRelief

    /// Wood or metal cabinet edges on the window frame. A screen-level
    /// decoration rather than a per-unit one, which is why no component in
    /// `DesignSystem` reads it — `RackScreen` does.
    public var usesSideCheeks: Bool

    public var meterStyle: MeterStyle

    public init(
        panelStyle: PanelStyle,
        displayStyle: DisplayStyle,
        cornerRadius: CGFloat,
        borderWidth: CGFloat,
        showsCentreDetent: Bool,
        isLight: Bool,
        knobStyle: KnobStyle,
        knobIndicatorStyle: KnobIndicatorStyle = .line,
        buttonStyle: ButtonStyle,
        panelRelief: PanelRelief,
        usesSideCheeks: Bool,
        meterStyle: MeterStyle
    ) {
        self.panelStyle = panelStyle
        self.displayStyle = displayStyle
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.showsCentreDetent = showsCentreDetent
        self.isLight = isLight
        self.knobStyle = knobStyle
        self.knobIndicatorStyle = knobIndicatorStyle
        self.buttonStyle = buttonStyle
        self.panelRelief = panelRelief
        self.usesSideCheeks = usesSideCheeks
        self.meterStyle = meterStyle
    }
}

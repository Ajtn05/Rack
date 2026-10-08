import SwiftUI

/// One light source for the entire window.
///
/// This is the single rule that separates skeuomorphism reading as physical
/// from skeuomorphism reading as noise. Every bevel, drop shadow, specular
/// highlight and needle shadow in the interface derives its direction from
/// here — so a panel, a knob standing on it and a needle swinging over it all
/// agree about where the light is coming from.
///
/// **A component must never hardcode a shadow offset.** It asks the lighting
/// for one. A single hardcoded `y: 2` somewhere is enough to break the effect
/// for the whole window, because the eye reads the *disagreement* long before
/// it reads any individual shadow.
public struct ThemeLighting: Equatable, Sendable {
    /// Where the light comes from, measured the way a compass bearing is:
    /// 315° is above and to the left, which is the convention essentially all
    /// physical-looking interfaces use and which macOS itself assumes.
    public var angle: Angle

    /// How high the source sits. Low elevation throws long shadows; high
    /// elevation throws short ones and reads as flatter.
    public var elevation: Double

    /// Fill light. Raise it to soften every shadow in the window at once —
    /// the lever a theme pulls when its relief is reading as too harsh.
    public var ambient: Double

    /// How hot the highlights are.
    public var specular: Double

    public init(
        angle: Angle = .degrees(315),
        elevation: Double = 0.6,
        ambient: Double = 0.5,
        specular: Double = 0.4
    ) {
        self.angle = angle
        self.elevation = elevation
        self.ambient = ambient
        self.specular = specular
    }

    /// The neutral top-left key light. A theme that says nothing gets this.
    public static let standard = ThemeLighting()

    /// Unit vector pointing *away* from the light — the direction a shadow
    /// falls. Screen coordinates, so positive `y` is downward.
    ///
    /// Computed once here rather than in each component, because "which way
    /// does a shadow go" is exactly the question a single light source exists
    /// to answer only once.
    public var shadowDirection: CGSize {
        let radians = angle.radians
        return CGSize(width: -cos(radians), height: sin(radians))
    }

    /// The opposite: the edge that catches the light.
    public var highlightDirection: CGSize {
        let d = shadowDirection
        return CGSize(width: -d.width, height: -d.height)
    }

    /// How far a shadow is thrown for a part standing `height` points proud
    /// of its surround. Low elevation stretches it; high elevation tucks it
    /// under the part.
    public func shadowOffset(forHeight height: CGFloat) -> CGSize {
        let reach = height * (1.4 - min(max(elevation, 0), 1))
        let d = shadowDirection
        return CGSize(width: d.width * reach, height: d.height * reach)
    }

    /// Blur for that shadow. Ambient light scatters it.
    public func shadowRadius(forHeight height: CGFloat) -> CGFloat {
        height * (0.6 + min(max(ambient, 0), 1) * 0.8)
    }

    /// How opaque a cast shadow should be. Ambient fill is what stops a
    /// shadow going to black.
    public var shadowStrength: Double {
        min(max(1 - ambient, 0), 1) * 0.55
    }
}

// MARK: - Bevels

/// How an edge is cut.
public enum BevelStyle: Equatable, Sendable {
    /// Stands proud: highlight on the light-facing edge, shadow opposite.
    case raised
    /// Recessed: the same two, swapped. A display window, a groove.
    case inset
    /// No relief at all.
    case flush
    /// Proud, but with the light wrapping round rather than breaking on an
    /// edge — a moulded cap rather than a milled one.
    case rounded
}

/// The edge treatment on a panel, knob, button or display window.
///
/// Carries only *how much* and *what kind*; which way round the highlight and
/// shadow go is not stored, because it is not a free choice — it follows from
/// `ThemeLighting.angle` and the style, and `BevelOverlay` derives it.
public struct ThemeBevel: Equatable, Sendable {
    public var width: Double
    public var style: BevelStyle
    public var highlightOpacity: Double
    public var shadowOpacity: Double

    public init(
        width: Double,
        style: BevelStyle,
        highlightOpacity: Double,
        shadowOpacity: Double
    ) {
        self.width = width
        self.style = style
        self.highlightOpacity = highlightOpacity
        self.shadowOpacity = shadowOpacity
    }

    /// No relief. What the flat themes use, and the sensible default for a
    /// theme that has not thought about it.
    public static let none = ThemeBevel(
        width: 0, style: .flush, highlightOpacity: 0, shadowOpacity: 0
    )

    /// Whether this bevel draws anything.
    public var isVisible: Bool { width > 0 && style != .flush }

    /// The same bevel, turned the other way. A knob cap that is `.raised` at
    /// rest is `.inset` while it is pressed, and that is the whole of the
    /// difference — nothing else about it changes.
    public var inverted: ThemeBevel {
        var copy = self
        switch style {
        case .raised: copy.style = .inset
        case .inset: copy.style = .raised
        case .flush, .rounded: break
        }
        return copy
    }
}

// MARK: - Type treatment

/// How a legend is physically part of the panel.
///
/// Labels on real equipment are printed into, cut into, or raised out of the
/// surface. Flat text sitting on a bevelled panel is the most common tell
/// that a skin is fake — it is the one element that betrays there is no
/// surface there at all.
public enum ThemeEngraving: Equatable, Sendable {
    /// Printed ink. No relief, because screen printing has none.
    case silkscreen
    /// Cut into the panel: a shadow above the stroke and a highlight below,
    /// which is what a groove does under a light from above.
    case engraved
    /// Raised out of it — the inverse.
    case embossed
    /// Engraved, then filled with paint. The cut plus a colour that is not
    /// the panel's.
    case etched(fill: Color)

    /// Whether this treatment draws relief at all.
    public var hasRelief: Bool {
        if case .silkscreen = self { return false }
        return true
    }
}

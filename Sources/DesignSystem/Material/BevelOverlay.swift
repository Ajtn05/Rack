import SwiftUI

/// Draws a `ThemeBevel` on a shape, with its direction taken from the
/// window's single light source.
///
/// The whole point of routing this through one type: no component decides
/// which edge is lit. `.raised` puts the highlight on the edge facing the
/// light and the shadow opposite; `.inset` swaps them. Both read the angle
/// from `ThemeLighting`, so changing that one number turns every bevel in the
/// window together.
struct BevelOverlay<S: InsettableShape>: View {
    @Environment(\.theme) private var theme
    @Environment(\.rackReduceTransparency) private var reduceTransparency

    let shape: S
    let bevel: ThemeBevel

    var body: some View {
        if bevel.isVisible, !reduceTransparency {
            // A rounded bevel wraps the light round the edge rather than
            // breaking it on a corner, so it gets a full sweep; the others
            // get a hard two-stop split.
            shape
                .strokeBorder(gradient, lineWidth: bevel.width)
                .allowsHitTesting(false)
        }
    }

    /// Highlight where the light lands, shadow where it does not.
    ///
    /// `.inset` is `.raised` with the two swapped and nothing else changed —
    /// which is exactly what a groove is next to a ridge.
    private var gradient: LinearGradient {
        let lighting = theme.lighting
        let lit = theme.colors.panelHighlight.opacity(bevel.highlightOpacity * lighting.specular * 2)
        let unlit = theme.colors.panelShadow.opacity(bevel.shadowOpacity * (1 - lighting.ambient * 0.5))

        let (start, end) = switch bevel.style {
        case .raised, .rounded:
            (lighting.highlightUnitPoint, lighting.shadowUnitPoint)
        case .inset:
            (lighting.shadowUnitPoint, lighting.highlightUnitPoint)
        case .flush:
            (UnitPoint.center, UnitPoint.center)
        }

        let stops: [Gradient.Stop] = switch bevel.style {
        case .rounded:
            // Light wrapping a curve: bright, then neutral across the crown,
            // then dark. A hard split on a rounded part reads as a crease.
            [
                .init(color: lit, location: 0),
                .init(color: .clear, location: 0.45),
                .init(color: .clear, location: 0.55),
                .init(color: unlit, location: 1)
            ]
        default:
            [
                .init(color: lit, location: 0),
                .init(color: .clear, location: 0.5),
                .init(color: unlit, location: 1)
            ]
        }

        return LinearGradient(stops: stops, startPoint: start, endPoint: end)
    }
}

extension View {
    /// Bevel this view's edge according to `bevel`, lit by the window's own
    /// light source.
    func bevelled<S: InsettableShape>(_ shape: S, _ bevel: ThemeBevel) -> some View {
        overlay(BevelOverlay(shape: shape, bevel: bevel))
    }

    /// Cast a shadow for a part standing `height` points proud of its
    /// surround, in the direction and at the length the lighting dictates.
    ///
    /// The alternative — a hardcoded offset — is the single most common way
    /// this kind of interface falls apart, because the eye reads the
    /// *disagreement* between two shadows long before it reads either one.
    func litShadow(height: CGFloat, lighting: ThemeLighting, color: Color) -> some View {
        let offset = lighting.shadowOffset(forHeight: height)
        return shadow(
            color: color.opacity(lighting.shadowStrength),
            radius: lighting.shadowRadius(forHeight: height),
            x: offset.width,
            y: offset.height
        )
    }
}

// MARK: - Engraving

/// Applies a `ThemeEngraving` to a piece of text.
///
/// Relief is drawn as two offset copies behind the glyphs — a dark one on the
/// side the light comes *from* and a light one opposite, which is what the
/// walls of a cut groove do. Offsets come from the lighting rather than being
/// fixed, so engraved type agrees with every bevel around it.
struct EngravedText: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.rackReduceTransparency) private var reduceTransparency

    let engraving: ThemeEngraving

    func body(content: Content) -> some View {
        // Silkscreen has no relief, and neither does the reduced-transparency
        // path — where the point is to remove exactly this kind of subtle
        // layered effect.
        guard engraving.hasRelief, !reduceTransparency else {
            return AnyView(content.foregroundStyle(fillColor ?? theme.colors.labelPrimary))
        }

        let lighting = theme.lighting
        // One point, the depth of an actual engraving. More than this stops
        // reading as a cut and starts reading as a drop shadow.
        let d = lighting.shadowDirection
        let depth: CGFloat = 1
        let lit = CGSize(width: -d.width * depth, height: -d.height * depth)
        let unlit = CGSize(width: d.width * depth, height: d.height * depth)

        // Engraved: the far wall of the groove catches light, the near wall
        // is in shadow. Embossed is the same two, swapped.
        let (shadowOffset, highlightOffset) = switch engraving {
        case .embossed: (lit, unlit)
        default: (unlit, lit)
        }

        return AnyView(
            content
                .foregroundStyle(fillColor ?? theme.colors.labelPrimary)
                .background(
                    content
                        .foregroundStyle(theme.colors.panelHighlight.opacity(0.55))
                        .offset(x: highlightOffset.width, y: highlightOffset.height)
                )
                .background(
                    content
                        .foregroundStyle(theme.colors.panelShadow.opacity(0.65))
                        .offset(x: shadowOffset.width, y: shadowOffset.height)
                )
        )
    }

    /// `.etched` carries its own paint; everything else takes the panel's
    /// label colour.
    private var fillColor: Color? {
        if case .etched(let fill) = engraving { return fill }
        return nil
    }
}

extension View {
    /// Treat this text as physically part of the panel.
    public func engraved(_ engraving: ThemeEngraving) -> some View {
        modifier(EngravedText(engraving: engraving))
    }
}

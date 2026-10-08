import SwiftUI

/// Renders a `ThemeMaterial`.
///
/// Base colour, then a directional sheen where the material has one, then the
/// procedural texture in `overlay` blend at a low amplitude. The whole thing
/// is wrapped in `drawingGroup()`, so a panel rasterises once and is reused
/// until its size or its theme changes — nothing here redraws per frame.
///
/// Accessibility: when the system asks for reduced transparency, every
/// material collapses to `baseColor`. The textures are centred on mid-grey so
/// that collapse does not shift any panel's luminance, which means the
/// contrast audit holds in both paths without a second set of numbers.
public struct MaterialSurface: View {
    @Environment(\.theme) private var theme
    @Environment(\.rackReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    private let material: ThemeMaterial

    public init(_ material: ThemeMaterial) {
        self.material = material
    }

    public var body: some View {
        ZStack {
            base
            if !reduceTransparency, material.isTextured {
                sheen
                texture
            }
        }
        // One rasterisation per size, reused until something actually
        // changes. Without this the texture recomposites on every unrelated
        // redraw of the panel it sits under.
        .drawingGroup()
    }

    /// The material's own colour, plus whatever gradient is part of the
    /// material rather than of the lighting — glass is the interesting case,
    /// since its curvature is a property of the pane, not of the panel.
    @ViewBuilder
    private var base: some View {
        switch material {
        case .glass(let tint, let reflection, let curvature):
            Rectangle().fill(tint)
            if !reduceTransparency {
                glassReflection(reflection: reflection, curvature: curvature)
            }
        default:
            Rectangle().fill(material.baseColor)
        }
    }

    /// A broad fall of light across the surface, in the direction the window's
    /// own light is coming from. Only the materials that are actually glossy
    /// get one.
    @ViewBuilder
    private var sheen: some View {
        let amount: Double = switch material {
        case .paintedSteel(_, let sheen, _): sheen
        case .enamel(_, let gloss): gloss
        case .anodised: 0.10
        case .brushedMetal: 0.08
        default: 0
        }

        if amount > 0 {
            let lighting = theme.lighting
            LinearGradient(
                colors: [
                    theme.colors.panelHighlight.opacity(min(amount, 0.35) * lighting.specular * 2),
                    .clear,
                    theme.colors.panelShadow.opacity(min(amount, 0.35) * 0.6)
                ],
                startPoint: lighting.highlightUnitPoint,
                endPoint: lighting.shadowUnitPoint
            )
        }
    }

    /// The procedural grain, tiled at one texture pixel per device pixel so
    /// nothing is ever scaled and nothing ever softens.
    @ViewBuilder
    private var texture: some View {
        if let request = material.textureRequest,
           let image = MaterialTexture.image(for: request) {
            Image(decorative: image, scale: displayScale)
                .resizable(resizingMode: .tile)
                // `overlay` treats mid-grey as the identity, so the texture
                // modulates the base without moving its mean.
                .blendMode(.overlay)
                .opacity(material.textureOpacity)
        }
    }

    /// The bright sweep across a curved pane. Deliberately weak: the scale
    /// underneath has to stay readable through it, and a reflection that
    /// obscures the thing it is protecting is a worse lie than no reflection.
    private func glassReflection(reflection: Double, curvature: Double) -> some View {
        let strength = min(max(reflection, 0), 0.4)
        let bend = min(max(curvature, 0), 1)
        return LinearGradient(
            stops: [
                .init(color: theme.colors.panelHighlight.opacity(strength), location: 0),
                .init(color: .clear, location: 0.28 + bend * 0.12),
                .init(color: .clear, location: 0.72),
                .init(color: theme.colors.panelHighlight.opacity(strength * 0.35), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .allowsHitTesting(false)
    }
}

extension ThemeLighting {
    /// The light's direction as a `UnitPoint`, for gradients that run from
    /// the lit edge to the shaded one.
    var highlightUnitPoint: UnitPoint {
        let d = highlightDirection
        return UnitPoint(x: 0.5 + d.width * 0.5, y: 0.5 + d.height * 0.5)
    }

    var shadowUnitPoint: UnitPoint {
        let d = shadowDirection
        return UnitPoint(x: 0.5 + d.width * 0.5, y: 0.5 + d.height * 0.5)
    }
}

import SwiftUI

/// What a surface is made of.
///
/// A procedural description, never an image: each case carries a base colour
/// plus the handful of numbers its texture needs, and `MaterialSurface` turns
/// that into pixels. A theme therefore stays one Swift file, and a surface is
/// tuned by changing a number rather than by re-exporting art.
///
/// **Keep the intensities low.** The difference between a panel that reads as
/// painted steel and one that reads as a JPEG artefact is almost entirely
/// amplitude. Every `…Opacity`, `mottle`, `orangePeel` and `figure` here is a
/// 0…1 fraction, and the convincing range for nearly all of them is below
/// 0.15. The renderer clamps them, but the clamp is a backstop, not a licence.
public enum ThemeMaterial: Equatable, Sendable {
    /// No texture at all. What every theme before the material system was,
    /// and what the flat themes still want.
    case flat(Color)

    /// Directional grain stretched along one axis — a panel that has been
    /// wire-brushed.
    case brushedMetal(base: Color, axis: Axis, grainScale: Double, grainOpacity: Double)

    /// Paint over steel: a broad sheen plus the low-frequency undulation of a
    /// finish that did not flow out perfectly flat.
    case paintedSteel(base: Color, sheen: Double, orangePeel: Double)

    /// Moulded phenolic — warped, blotchy, and darker in the hollows.
    case bakelite(base: Color, mottle: Double)

    /// Baked enamel: near-flat with a glossy fall of light across it.
    case enamel(base: Color, gloss: Double)

    /// Banded grain with occasional figure across it.
    case wood(tone: Color, grainScale: Double, figure: Double)

    /// A pane in front of something else. Tinted, with a curvature-driven
    /// reflection — the only material that expects to be composited *over*
    /// content rather than under it.
    case glass(tint: Color, reflection: Double, curvature: Double)

    /// Speaker cloth, for large empty areas.
    case clothGrille(base: Color, weaveScale: Double)

    /// Anodised aluminium: finer and more even than `brushedMetal`.
    case anodised(base: Color, grainOpacity: Double)

    /// The colour this material averages to.
    ///
    /// Every texture is centred on mid-grey and composited in `overlay`
    /// blend, which leaves the mean where the base put it — so this is not an
    /// approximation, it is the luminance the contrast audit should check
    /// text against, and the colour the reduced-transparency path falls back
    /// to.
    public var baseColor: Color {
        switch self {
        case .flat(let c): c
        case .brushedMetal(let c, _, _, _): c
        case .paintedSteel(let c, _, _): c
        case .bakelite(let c, _): c
        case .enamel(let c, _): c
        case .wood(let c, _, _): c
        case .glass(let c, _, _): c
        case .clothGrille(let c, _): c
        case .anodised(let c, _): c
        }
    }

    /// Whether this material puts anything at all on top of its base colour.
    /// A `.flat` surface skips the whole texture path, which is what keeps
    /// the existing themes costing exactly what they did before.
    public var isTextured: Bool {
        if case .flat = self { return false }
        return true
    }

    /// The texture to generate, or nil for a material that is only colour and
    /// gradient. Seeded per material so two panels of the same description
    /// share one cached tile and never disagree about their own grain.
    public var textureRequest: MaterialTextureRequest? {
        switch self {
        case .flat:
            nil
        case .brushedMetal(_, let axis, let scale, _):
            MaterialTextureRequest(
                pattern: .brushed(horizontal: axis == .horizontal),
                scale: max(scale, 0.5), seed: 0x5EED_B045
            )
        case .paintedSteel:
            MaterialTextureRequest(pattern: .orangePeel, scale: 48, seed: 0x0A11_7ED5)
        case .bakelite:
            MaterialTextureRequest(pattern: .mottle, scale: 36, seed: 0xBA4E_117E)
        case .enamel:
            MaterialTextureRequest(pattern: .fine, scale: 3, seed: 0xE4A_3E11)
        case .wood(_, let scale, let figure):
            MaterialTextureRequest(
                pattern: .wood(figure: min(max(figure, 0), 1)),
                scale: max(scale, 1), seed: 0x0D00_7A11
            )
        case .glass:
            nil
        case .clothGrille(_, let scale):
            MaterialTextureRequest(pattern: .weave, scale: max(scale, 1), seed: 0xC107_4111)
        case .anodised:
            MaterialTextureRequest(
                pattern: .brushed(horizontal: true), scale: 2, seed: 0xA110_D15E
            )
        }
    }

    /// How strongly the texture is composited. Clamped hard: see the note on
    /// amplitude in this type's own documentation.
    public var textureOpacity: Double {
        let raw: Double = switch self {
        case .flat: 0
        case .brushedMetal(_, _, _, let o): o
        case .paintedSteel(_, _, let peel): peel
        case .bakelite(_, let mottle): mottle
        case .enamel(_, let gloss): gloss * 0.25
        case .wood: 0.35
        case .glass: 0
        case .clothGrille: 0.30
        case .anodised(_, let o): o
        }
        return min(max(raw, 0), 0.6)
    }
}

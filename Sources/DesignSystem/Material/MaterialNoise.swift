import CoreGraphics
import Foundation

/// Procedural surface texture: value noise, generated from a seed rather than
/// loaded from an asset.
///
/// **Why this is not a bitmap in the bundle.** A shipped PNG panel is soft on
/// Retina at non-integer scale, bloats the download, cannot be resized, and
/// turns a theme from one editable Swift file into an art pipeline. Everything
/// here is computed from a seed, a scale and an intensity, so a theme stays a
/// single file and a new surface is a new set of numbers.
///
/// **Why this is not a Metal shader**, which is the other obvious way to do
/// it. The Metal compiler ships with Xcode's Metal Toolchain component, which
/// is not part of Command Line Tools — and this package is required to build
/// with Command Line Tools alone (see `ARCHITECTURE.md`). A `.metal` file
/// would make the build depend on a component that may not be installed.
///
/// So the generator runs on the CPU, and three properties make that fine:
///
/// - **It is tileable.** The lattice wraps at `Self.tilePixels`, so one
///   modest texture covers a panel of any size with no seam. Nothing scales,
///   so nothing softens: one texture pixel is one device pixel.
/// - **It is cached.** `MaterialTexture.image(for:)` generates once per
///   distinct description and hands back the same `CGImage` afterwards.
/// - **It never runs per frame.** Static chrome is wrapped in
///   `drawingGroup()`; only the analyzer and the meters redraw, and neither
///   asks for a texture.
///
/// The rendering path is deliberately behind `MaterialTexture`, so if the
/// Metal toolchain becomes a safe dependency later, a shader backend can
/// replace the body of this file without a single theme or component
/// changing.
enum MaterialNoise {
    /// A hash from two lattice coordinates and a seed to a value in 0…1.
    ///
    /// Integer mixing rather than `sin`-based hashing: the trigonometric trick
    /// is shorter but its quality varies wildly with magnitude, and it
    /// produces visible diagonal structure at exactly the low amplitudes this
    /// system uses.
    @inline(__always)
    static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = seed &+ UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h = h ^ (UInt64(bitPattern: Int64(y)) &* 0xBF58_476D_1CE4_E5B9)
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h = h ^ (h >> 31)
        return Double(h >> 11) / Double(1 << 53)
    }

    /// Smoothstep, for interpolating between lattice points without the
    /// visible grid a linear blend leaves behind.
    @inline(__always)
    private static func fade(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Value noise on a lattice that wraps every `period` cells, so the
    /// result tiles seamlessly.
    @inline(__always)
    static func value(_ x: Double, _ y: Double, period: Int, seed: UInt64) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = fade(x - Double(x0)), fy = fade(y - Double(y0))

        // The wrap is what makes this tile: a lattice coordinate past the
        // period reads the same corner as its counterpart at the far edge.
        func wrap(_ v: Int) -> Int {
            let m = v % period
            return m < 0 ? m + period : m
        }
        let xa = wrap(x0), xb = wrap(x0 + 1)
        let ya = wrap(y0), yb = wrap(y0 + 1)

        let top = hash(xa, ya, seed) + fx * (hash(xb, ya, seed) - hash(xa, ya, seed))
        let bottom = hash(xa, yb, seed) + fx * (hash(xb, yb, seed) - hash(xa, yb, seed))
        return top + fy * (bottom - top)
    }

    /// Several octaves of `value`, each finer and quieter than the last.
    ///
    /// The period doubles with the frequency so every octave keeps tiling on
    /// the same boundary.
    static func fbm(
        _ x: Double, _ y: Double,
        octaves: Int, basePeriod: Int, seed: UInt64
    ) -> Double {
        var total = 0.0, amplitude = 1.0, normalisation = 0.0
        var frequency = 1.0
        var period = basePeriod

        for octave in 0..<max(octaves, 1) {
            total += amplitude * value(
                x * frequency, y * frequency,
                period: period, seed: seed &+ UInt64(octave) &* 0x1234_5678
            )
            normalisation += amplitude
            amplitude *= 0.5
            frequency *= 2
            period *= 2
        }
        return normalisation > 0 ? total / normalisation : 0.5
    }
}

// MARK: - Texture generation

/// What a texture should look like, reduced to the handful of numbers the
/// generator actually needs. Hashable so it can key the cache — two themes
/// asking for the same grain share one image.
public struct MaterialTextureRequest: Hashable {
    public enum Pattern: Hashable {
        /// Directional grain, stretched along an axis. Brushed metal and
        /// anodised aluminium.
        case brushed(horizontal: Bool)
        /// Low-frequency undulation. Paint that did not flow out flat.
        case orangePeel
        /// Warped two-octave blotching. Bakelite.
        case mottle
        /// Bands across the grain with occasional figure. Wood.
        case wood(figure: Double)
        /// A regular over-under weave. Speaker cloth.
        case weave
        /// Fine even tooth, for enamel and glass.
        case fine
    }

    public var pattern: Pattern
    /// How large the features are. Bigger means coarser.
    public var scale: Double
    public var seed: UInt64
}

/// Generates and caches the textures `MaterialSurface` draws.
public enum MaterialTexture {
    /// The tile is square, a power of two, and generated at 1:1 device
    /// pixels. 256 is enough that repetition is invisible for grain and
    /// cheap enough that a first render is imperceptible — the whole tile is
    /// 65k samples, generated once per distinct material for the life of the
    /// process.
    public static let tilePixels = 256

    /// Cache keyed on the request. Not an `NSCache`: the set of distinct
    /// materials is bounded by the number of themes times the surfaces each
    /// describes, which is tens, and evicting one only to regenerate it on
    /// the next resize is worse than keeping it.
    private nonisolated(unsafe) static var cache: [MaterialTextureRequest: CGImage] = [:]
    private static let lock = NSLock()

    public static func image(for request: MaterialTextureRequest) -> CGImage? {
        lock.lock()
        if let hit = cache[request] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let made = render(request) else { return nil }

        lock.lock()
        cache[request] = made
        lock.unlock()
        return made
    }

    /// Greyscale, centred on mid-grey. The surface composites it in `overlay`
    /// blend, where mid-grey is the identity — so the texture lightens where
    /// it is above 128 and darkens where it is below, and its *average*
    /// leaves the base colour where the theme put it.
    ///
    /// That last property is what keeps the contrast audit honest: a grain
    /// that shifted the mean would quietly move every panel's luminance away
    /// from the value its text was checked against.
    private static func render(_ request: MaterialTextureRequest) -> CGImage? {
        let size = tilePixels
        let period = max(Int((Double(size) / max(request.scale, 1)).rounded()), 2)
        var pixels = [UInt8](repeating: 128, count: size * size)

        for y in 0..<size {
            for x in 0..<size {
                let u = Double(x) / request.scale
                let v = Double(y) / request.scale
                let n = sample(request, u: u, v: v, period: period)
                // 0…1 to 0…255, centred so 0.5 lands exactly on 128.
                pixels[y * size + x] = UInt8(max(0, min(255, (n * 255).rounded())))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray)
        else { return nil }

        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: size,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// One sample, in 0…1 and centred on 0.5.
    private static func sample(
        _ request: MaterialTextureRequest, u: Double, v: Double, period: Int
    ) -> Double {
        let seed = request.seed

        switch request.pattern {
        case .brushed(let horizontal):
            // Directional grain: sample with one axis stretched far out, so
            // features smear into long fibres along it. The stretch factor is
            // what makes this read as *brushed* rather than as dirt.
            let stretch = 24.0
            let (a, b) = horizontal ? (u / stretch, v) : (u, v / stretch)
            let p = max(period, 2)
            let fine = MaterialNoise.value(a, b, period: p, seed: seed)
            let finer = MaterialNoise.value(a * 3, b * 3, period: p * 3, seed: seed &+ 7)
            return 0.5 + ((fine * 0.6 + finer * 0.4) - 0.5) * 0.9

        case .orangePeel:
            // Low frequency and gentle — paint that settled unevenly, not a
            // hammered finish.
            return 0.5 + (MaterialNoise.fbm(u, v, octaves: 2, basePeriod: period, seed: seed) - 0.5) * 0.8

        case .mottle:
            // Warped noise: offset the lookup by another noise field so the
            // blotches wander instead of sitting on a grid.
            let wx = MaterialNoise.value(u * 0.5, v * 0.5, period: max(period / 2, 2), seed: seed &+ 11)
            let wy = MaterialNoise.value(u * 0.5 + 5, v * 0.5 + 5, period: max(period / 2, 2), seed: seed &+ 13)
            let warped = MaterialNoise.fbm(
                u + (wx - 0.5) * 2, v + (wy - 0.5) * 2,
                octaves: 2, basePeriod: period, seed: seed
            )
            return 0.5 + (warped - 0.5) * 1.0

        case .wood(let figure):
            // Bands across the grain, with the band positions themselves
            // perturbed so the rings are not ruler-straight.
            let wander = MaterialNoise.fbm(u * 0.3, v * 0.08, octaves: 2, basePeriod: period, seed: seed)
            let rings = sin((v + (wander - 0.5) * 3) * .pi * 2)
            // Occasional figure — the darker flecks across the grain.
            let fleck = MaterialNoise.value(u * 4, v * 12, period: period * 4, seed: seed &+ 17)
            let combined = rings * 0.5 + (fleck - 0.5) * figure
            return 0.5 + combined * 0.5

        case .weave:
            // Over-under: two out-of-phase sinusoids, which is what a plain
            // weave is when you stand far enough back.
            let warp = sin(u * .pi * 2)
            let weft = sin(v * .pi * 2 + .pi / 2)
            let jitter = MaterialNoise.value(u, v, period: max(period, 2), seed: seed) - 0.5
            return 0.5 + (warp * weft * 0.5 + jitter * 0.3) * 0.5

        case .fine:
            let n = MaterialNoise.value(u, v, period: max(period, 2), seed: seed)
            return 0.5 + (n - 0.5) * 0.6
        }
    }
}

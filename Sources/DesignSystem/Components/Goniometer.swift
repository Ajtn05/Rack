import SwiftUI

/// A vectorscope: raw stereo sample pairs, plotted as a point cloud rather
/// than reduced to a single number.
///
/// Deliberately ignorant of where its points came from — same discipline
/// `ResponseCurve` documents for itself. Every point arrives already rotated
/// and normalized to `[-1, 1]` on both axes; whatever produced that rotation
/// (a phase transform, a mid/side matrix) is a decision about audio, not
/// about drawing, and stays out of this file.
///
/// The rotation the caller is expected to have applied is the classic one: a
/// mono signal (`left == right`) should land on the *vertical* axis, and a
/// fully out-of-phase one (`left == -right`) on the *horizontal* — every
/// hardware goniometer since the Lissajous tube has been wired this way, and
/// the axes drawn here assume it.
public struct Goniometer: View {
    @Environment(\.theme) private var theme

    /// One stereo sample, already rotated: `x` is the stereo difference
    /// (side), `y` is the stereo sum (mid), both `[-1, 1]`.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    private let points: [Point]
    private let isDimmed: Bool

    /// - Parameter isDimmed: drawn in the idle colour rather than the lit
    ///   one, the same convention `SpectrumBars` and `NeedleMeter` use for a
    ///   display that has gone quiet from disuse.
    public init(points: [Point], isDimmed: Bool = false) {
        self.points = points
        self.isDimmed = isDimmed
    }

    public var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Half the shorter side, so the scope stays circular rather than
            // stretching a signal at full deflection into an ellipse on a
            // rectangular panel.
            let radius = min(size.width, size.height) / 2

            var axes = Path()
            axes.move(to: CGPoint(x: center.x, y: 0))
            axes.addLine(to: CGPoint(x: center.x, y: size.height))
            axes.move(to: CGPoint(x: 0, y: center.y))
            axes.addLine(to: CGPoint(x: size.width, y: center.y))
            context.stroke(axes, with: .color(theme.colors.readoutDim), lineWidth: hairline)

            guard !points.isEmpty else { return }

            let dotColor = isDimmed
                ? theme.colors.controlIdle
                : (theme.colors.readoutLevel ?? theme.colors.meterNominal)

            // Semi-transparent and drawn with plain `.fill` rather than
            // `.blendMode(.plusLighter)`: overlapping dots still deepen
            // where the signal actually spends its time — closer to a
            // phosphor's brightness than a flat cloud — without pulling in
            // a blend mode that reads wrong against a light theme's panel.
            //
            // Square dots rather than round ones, and that is a cost decision
            // with no visual consequence worth the name. `addEllipse` emits
            // four cubic Béziers per dot; a whole window of them is a couple of
            // thousand curve segments to flatten and rasterise, thirty times a
            // second, for marks that are barely two points across. `addRect` is
            // four straight edges. At this size, against a cloud this dense, the
            // difference is not visible — a phosphor dot on real glass is not a
            // clean circle either — and it is the bulk of what this display was
            // costing to draw.
            let size = dotRadius * 2
            var dots = Path()
            for point in points {
                let x = center.x + CGFloat(clamp(point.x)) * radius - dotRadius
                let y = center.y - CGFloat(clamp(point.y)) * radius - dotRadius
                dots.addRect(CGRect(x: x, y: y, width: size, height: size))
            }
            context.fill(dots, with: .color(dotColor.opacity(0.55)))
        }
        // Same reserved height every other analyzer display uses
        // (`SpectrumBars`, `ResponseCurve`, `NeedleMeter`) — without it a
        // `Canvas` has no intrinsic size and collapses to whatever sliver
        // its siblings in the panel's stack leave behind.
        .frame(height: theme.metrics.graphHeight)
        // No implicit animation. Each poll's window is a fresh picture, not
        // an interpolation from the last one — the same reasoning
        // `LevelMeter` documents for its own ballistics.
        .animation(nil, value: points)
    }

    private let dotRadius: CGFloat = 1.1
    private var hairline: CGFloat { max(theme.chrome.borderWidth, 1) }

    private func clamp(_ value: Double) -> Double { min(max(value, -1), 1) }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct Goniometer_Previews: PreviewProvider {
    /// A rough ellipse leaning toward mono, with some scatter — enough shape
    /// that a skin drawing the axes backwards, or the dots in an invisible
    /// colour, is obvious on sight.
    static var sample: [Goniometer.Point] {
        (0..<300).map { index in
            let t = Double(index) / 300 * .pi * 2
            let jitter = Double((index * 37) % 11) / 11 - 0.5
            return Goniometer.Point(
                x: 0.35 * sin(t) + jitter * 0.15,
                y: 0.85 * cos(t) + jitter * 0.15
            )
        }
    }

    static var previews: some View {
        ThemeGallery {
            Goniometer(points: sample)
                .frame(width: 160, height: 160)

            Goniometer(points: sample, isDimmed: true)
                .frame(width: 160, height: 160)

            // Nothing to draw. The axes still have to appear.
            Goniometer(points: [])
                .frame(width: 160, height: 160)
        }
    }
}

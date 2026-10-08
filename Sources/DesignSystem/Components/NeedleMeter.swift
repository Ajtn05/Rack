import SwiftUI

/// A moving-coil meter: a lit face, a printed scale, a needle, and optionally
/// a pane of glass over the whole thing.
///
/// Like every component here it takes a number already reduced to the units it
/// draws in — `position` is 0…1 across the scale, and whatever produced it
/// (ballistics, a transform, a survey) is not this file's business. Nothing
/// below names a decibel or a VU.
///
/// **The needle casts a shadow onto the face, and the face is lit from the
/// window's own light source.** That is the detail that makes a drawn meter
/// read as a physical instrument rather than as a dial illustration: the
/// needle is a thin piece of metal sitting a millimetre above the printed
/// card, and at any real light angle it throws a visible offset shadow.
public struct NeedleMeter: View {
    @Environment(\.theme) private var theme
    @Environment(\.rackReduceTransparency) private var reduceTransparency

    /// Where the needle points, 0 at the left end of the scale and 1 at the
    /// right.
    private let position: Double

    /// Where the warning region begins, in the same 0…1 space. Above this the
    /// scale is printed in `meterZoneWarning`.
    private let warningThreshold: Double

    /// Legends printed on the face, each with its own 0…1 position.
    private let marks: [Mark]

    private let caption: String?

    /// True when the reading behind this needle is not to be trusted — the
    /// engine is off, or the display has gone idle. The needle and scale draw
    /// in `controlIdle` instead of their usual inks, the same treatment
    /// `SpectrumBars` gives its bars for the same reason.
    private let isDimmed: Bool

    public struct Mark: Equatable, Sendable {
        public let position: Double
        public let label: String?
        /// A long tick is one worth reading against; a short one is there to
        /// be counted.
        public let isMajor: Bool

        public init(position: Double, label: String? = nil, isMajor: Bool = true) {
            self.position = position
            self.label = label
            self.isMajor = isMajor
        }
    }

    public init(
        position: Double,
        warningThreshold: Double = 0.75,
        marks: [Mark] = NeedleMeter.vuMarks,
        caption: String? = nil,
        isDimmed: Bool = false
    ) {
        self.position = position
        self.warningThreshold = warningThreshold
        self.marks = marks
        self.caption = caption
        self.isDimmed = isDimmed
    }

    /// The classic VU legend: −20 to +3, with the numbered marks a real face
    /// carries and unnumbered ticks between them.
    public static let vuMarks: [Mark] = [
        Mark(position: 0.00, label: "−20"),
        Mark(position: 0.13, label: nil, isMajor: false),
        Mark(position: 0.26, label: "−10"),
        Mark(position: 0.38, label: nil, isMajor: false),
        Mark(position: 0.50, label: "−5"),
        Mark(position: 0.62, label: nil, isMajor: false),
        Mark(position: 0.75, label: "0"),
        Mark(position: 0.87, label: nil, isMajor: false),
        Mark(position: 1.00, label: "+3")
    ]

    /// A gain-reduction legend: 0 dB rests at the right, exactly like a real
    /// compressor's meter, and the needle swings left as reduction deepens
    /// — the mirror image of `vuMarks`' "louder is further right", because
    /// what this face reports is the opposite kind of thing. Evenly spaced,
    /// unlike `vuMarks`: a compressor's meter has no reason to compress its
    /// own scale, only the signal.
    public static let gainReductionMarks: [Mark] = [
        Mark(position: 0.00, label: "−20"),
        Mark(position: 0.25, label: "−15"),
        Mark(position: 0.50, label: "−10"),
        Mark(position: 0.75, label: "−5"),
        Mark(position: 1.00, label: "0")
    ]

    /// The needle sweeps this many degrees, centred on vertical. A real VU
    /// movement travels about 90°; much more reads as a speedometer.
    private static let sweepDegrees: Double = 84

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // The pivot sits below the face's bottom edge, which is what puts
            // the needle's arc across the top of the scale the way a real
            // movement does.
            let pivot = CGPoint(x: size.width / 2, y: size.height * 1.06)
            let needleLength = size.height * 0.86

            ZStack {
                MaterialSurface(theme.meterFaceMaterial)

                scale(in: size, pivot: pivot, radius: needleLength)

                if let caption {
                    Text(caption)
                        .font(theme.typography.caption)
                        .foregroundStyle(isDimmed ? theme.colors.controlIdle : theme.colors.meterScale)
                        .position(x: size.width / 2, y: size.height * 0.62)
                }

                needle(pivot: pivot, length: needleLength)

                if let glass = theme.meterGlass, !reduceTransparency {
                    MaterialSurface(glass)
                        .allowsHitTesting(false)
                }
            }
            // A meter is set *into* the panel, so its bevel is normally
            // `.inset` — the theme says which, this only asks.
            .bevelled(
                RoundedRectangle(cornerRadius: theme.chrome.cornerRadius),
                theme.displayBevel
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.chrome.cornerRadius))
        }
        .frame(height: theme.metrics.graphHeight)
        // The ballistics upstream are the only smoothing wanted; SwiftUI
        // adding its own on top of a thirty-per-second update reads as lag.
        .animation(nil, value: position)
    }

    // MARK: - Face

    /// Ticks and legends, printed on the card.
    private func scale(in size: CGSize, pivot: CGPoint, radius: CGFloat) -> some View {
        ForEach(marks.indices, id: \.self) { index in
            let mark = marks[index]
            let angle = angleFor(mark.position)
            let isWarning = mark.position >= warningThreshold
            let ink =
                isDimmed
                ? theme.colors.controlIdle
                : (isWarning ? theme.colors.meterZoneWarning : theme.colors.meterScale)
            let tickLength = size.height * (mark.isMajor ? 0.12 : 0.07)

            // Ticks are drawn along the needle's own arc, so they line up with
            // where it actually points rather than with a straight ruler.
            Capsule()
                .fill(ink)
                .frame(width: max(size.width * 0.006, 1), height: tickLength)
                .offset(y: -(radius - tickLength / 2))
                .rotationEffect(.degrees(angle))
                .position(x: pivot.x, y: pivot.y)

            if let label = mark.label {
                // Placed by direct trigonometry rather than
                // `.offset(...).rotationEffect(angle)` the way the tick
                // above is: a `rotationEffect(angle)` immediately followed
                // by `rotationEffect(-angle, anchor: .center)` — meant to
                // sweep the label to its angle and then counter-rotate only
                // the glyphs upright — composes to the identity rotation
                // instead, since both share the same anchor. Every label
                // ended up rendered at the same un-rotated point straight
                // above the pivot, stacked on top of each other into one
                // illegible blob. Computing the swept point directly and
                // never rotating the text at all gets the same "upright
                // legend, positioned along the arc" result without the
                // cancellation.
                let labelRadius = radius - tickLength - size.height * 0.10
                let radians = angle * .pi / 180
                let labelPoint = CGPoint(
                    x: pivot.x + labelRadius * sin(radians),
                    y: pivot.y - labelRadius * cos(radians)
                )
                Text(label)
                    .font(theme.typography.caption)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
                    .position(labelPoint)
            }
        }
    }

    // MARK: - Needle

    private func needle(pivot: CGPoint, length: CGFloat) -> some View {
        let angle = angleFor(position)
        let lighting = theme.lighting
        // The needle floats a millimetre or so above the card. That height is
        // what the shadow's offset and blur both come from, so the shadow
        // agrees with every other lit thing in the window.
        let float = length * 0.035
        let offset = lighting.shadowOffset(forHeight: float)

        return ZStack {
            // The cast shadow, drawn as its own rotated copy rather than as a
            // `.shadow` modifier — a modifier would blur the needle's own
            // colour and could not be offset independently of it.
            if !reduceTransparency {
                needleShape(length: length)
                    .fill(theme.colors.panelShadow.opacity(lighting.shadowStrength))
                    .blur(radius: lighting.shadowRadius(forHeight: float) * 0.5)
                    .rotationEffect(.degrees(angle), anchor: .bottom)
                    .offset(x: offset.width, y: offset.height)
            }

            needleShape(length: length)
                .fill(isDimmed ? theme.colors.controlIdle : theme.colors.meterNeedle)
                .rotationEffect(.degrees(angle), anchor: .bottom)
        }
        .frame(width: length * 0.06, height: length)
        .position(x: pivot.x, y: pivot.y - length / 2)
        .overlay(
            // The hub the needle is pinned through.
            Circle()
                .fill(isDimmed ? theme.colors.controlIdle : theme.colors.meterNeedle)
                .frame(width: length * 0.10, height: length * 0.10)
                .position(x: pivot.x, y: pivot.y)
        )
    }

    /// Tapered: wide at the pivot, fine at the tip, the way a balanced
    /// pointer is made.
    private func needleShape(length: CGFloat) -> some Shape {
        NeedleShape()
    }

    private func angleFor(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return -Self.sweepDegrees / 2 + clamped * Self.sweepDegrees
    }
}

/// A pointer: a narrow triangle with a flat tip.
private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipWidth = rect.width * 0.28
        path.move(to: CGPoint(x: rect.midX - tipWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + tipWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct NeedleMeter_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            // At rest, mid-scale, and pinned — the three positions a meter
            // has to stay legible at.
            NeedleMeter(position: 0, caption: "VU").frame(width: 200)
            NeedleMeter(position: 0.6, caption: "VU").frame(width: 200)
            NeedleMeter(position: 1, caption: "VU").frame(width: 200)
        }
    }
}

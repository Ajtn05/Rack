import SwiftUI

/// A row of bars with peak markers over them.
///
/// Like every component here it takes numbers that have already been reduced to
/// the units it draws in: each bar is a fraction of the height, and whatever
/// produced those fractions — a transform, a meter, a survey — is not this
/// file's business. Nothing below names a frequency or a decibel.
///
/// The peak marker is the one place in the interface where the hold colour
/// carries its literal meaning. Elsewhere that colour says "engaged"; here it
/// says "this is how loud it just was", which is what a peak-hold marker on
/// real equipment says and why it was given a colour of its own.
public struct SpectrumBars: View {
    @Environment(\.theme) private var theme

    /// One bar.
    public struct Band: Equatable, Sendable {
        /// 0 at the bottom of the display, 1 at the top.
        public let level: Double

        /// The held maximum, in the same 0…1 space.
        public let hold: Double

        /// Legend beneath this bar, if it earns one. Most do not: labelling
        /// thirty-one bars produces a solid line of unreadable text, so the
        /// caller names a few landmarks and leaves the rest to be counted.
        public let label: String?

        public init(level: Double, hold: Double, label: String? = nil) {
            self.level = level
            self.hold = hold
            self.label = label
        }
    }

    private let bands: [Band]
    private let isDimmed: Bool
    private let drawsPlate: Bool

    /// - Parameter drawsPlate: false when this sits inside something that
    ///   already drew the glass — a `VFDPlate` grouping this with a meter and
    ///   a peak digit, say — so a second plate is not painted over the first.
    public init(bands: [Band], isDimmed: Bool = false, drawsPlate: Bool = true) {
        self.bands = bands
        self.isDimmed = isDimmed
        self.drawsPlate = drawsPlate
    }

    public var body: some View {
        VStack(spacing: theme.metrics.tightSpacing / 2) {
            // One `Canvas` for the whole row, rather than a `GeometryReader`
            // over an `HStack` of per-band `ZStack`s.
            //
            // This is the display that redraws most often and it was the most
            // expensive way to draw it: thirty-one bands times a track, a level
            // and a marker is ninety-three shape views, rebuilt and laid out
            // thirty times a second, every one of them carrying its own
            // animation modifiers and its own participation in the layout pass.
            // None of that bought anything — the bars are a picture, not
            // controls; nothing is hit-tested, focused or animated
            // independently.
            //
            // Drawn here as three accumulated paths — every track, every level,
            // every marker — and three fills. The view tree below this point is
            // one node whatever the band count, and the layout pass has nothing
            // left to do.
            Canvas(opaque: false) { context, size in
                draw(in: context, size: size)
            }

            if hasLegend {
                HStack(spacing: gap) {
                    ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                        Text(band.label ?? "")
                            .font(theme.typography.caption)
                            .foregroundStyle(theme.colors.labelSecondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(theme.metrics.tightSpacing)
        // The same overall height as the response curve, so switching between
        // the two does not shuffle everything below them up and down.
        .frame(height: theme.metrics.graphHeight)
        .background(plate)
        .overlay(border)
        // No implicit animation: the ballistics upstream are the only smoothing
        // wanted, and SwiftUI adding its own on top of a thirty-per-second
        // update reads as lag. One modifier over the whole row now, rather than
        // two on each of thirty-one bars.
        .animation(nil, value: bands)
    }

    // MARK: - Pieces

    /// Skipped entirely when something else already drew the glass this
    /// sits on.
    @ViewBuilder
    private var plate: some View {
        if drawsPlate {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .fill(theme.colors.readoutBackground)
        }
    }

    /// Every band's track, level and peak marker, as three accumulated paths.
    ///
    /// Column geometry matches what the `HStack` of equal-width bars produced,
    /// and must keep matching: the legend row below is still an `HStack` with
    /// the same `gap`, so a bar and its label line up only while both divide
    /// the width the same way.
    private func draw(in context: GraphicsContext, size: CGSize) {
        guard !bands.isEmpty, size.width > 0, size.height > 0 else { return }

        let height = size.height
        let count = CGFloat(bands.count)
        // N equal columns separated by N−1 gaps, which is what
        // `HStack(spacing:)` over `.frame(maxWidth: .infinity)` children gives.
        let barWidth = max((size.width - gap * (count - 1)) / count, 0)
        guard barWidth > 0 else { return }

        let corner = theme.chrome.cornerRadius / 2
        let marker = max(theme.chrome.borderWidth, 1) * 2

        var tracks = Path()
        var levels = Path()
        var markers = Path()

        for (index, band) in bands.enumerated() {
            let x = CGFloat(index) * (barWidth + gap)
            let level = clamp(band.level)
            let hold = clamp(band.hold)

            tracks.addRoundedRect(
                in: CGRect(x: x, y: 0, width: barWidth, height: height),
                cornerSize: CGSize(width: corner, height: corner)
            )

            let levelHeight = height * level
            if levelHeight > 0 {
                levels.addRoundedRect(
                    in: CGRect(
                        x: x, y: height - levelHeight, width: barWidth, height: levelHeight
                    ),
                    cornerSize: CGSize(width: corner, height: corner)
                )
            }

            // Held clear of the top edge by its own thickness, or a band at
            // full scale puts the marker half outside the display. Skipped
            // outright at rest rather than drawn transparent, which is what the
            // old `.opacity(hold > 0 ? 1 : 0)` amounted to.
            if hold > 0 {
                let offset = min(max(0, height * hold - marker), height - marker)
                markers.addRect(
                    CGRect(
                        x: x, y: height - marker - offset, width: barWidth, height: marker
                    )
                )
            }
        }

        // `readoutDim`, not `controlTrack`. A bar's unlit portion is a mark on
        // the *display's own glass*, and `controlTrack` is calibrated against
        // the panel — which is the same thing only on a theme whose panel and
        // display are a similar shade.
        //
        // `RackSteel` is where that broke: a light aluminium panel with
        // near-black display windows, so a panel-calibrated track drew pale grey
        // columns on black glass and the unlit part of every bar read as the lit
        // part. Exactly the sort of assumption a light theme with dark displays
        // exists to find.
        context.fill(tracks, with: .color(theme.colors.readoutDim))

        // `readoutLevel`, when a theme sets one — see its doc comment for why
        // `meterNominal` alone cannot serve this and a panel-mounted meter's
        // groove at once on every theme.
        context.fill(
            levels,
            with: .color(
                isDimmed
                    ? theme.colors.controlIdle
                    : (theme.colors.readoutLevel ?? theme.colors.meterNominal)
            )
        )

        // `readoutHold`, when a theme sets one — the peak marker's own
        // dual-context bind, mirroring `readoutLevel` just above.
        context.fill(
            markers,
            with: .color(
                isDimmed
                    ? theme.colors.controlIdle
                    : (theme.colors.readoutHold ?? theme.colors.meterHold)
            )
        )
    }

    @ViewBuilder
    private var border: some View {
        if drawsPlate, theme.chrome.borderWidth > 0 {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .strokeBorder(theme.colors.panelBorder, lineWidth: theme.chrome.borderWidth)
        }
    }

    private var gap: CGFloat { theme.metrics.tightSpacing / 2 }

    private var hasLegend: Bool { bands.contains { $0.label != nil } }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct SpectrumBars_Previews: PreviewProvider {
    /// Something with a shape to it, so a skin that maps the height backwards
    /// or loses the peak markers is obvious on sight.
    static var sample: [SpectrumBars.Band] {
        let labels = [3: "50", 10: "200", 17: "1k", 24: "5k", 30: "20k"]
        return (0..<31).map { index in
            let position = Double(index) / 30
            let level = max(0, 0.75 - 0.5 * position + 0.22 * sin(position * .pi * 6))
            return SpectrumBars.Band(
                level: level,
                hold: min(1, level + 0.12),
                label: labels[index]
            )
        }
    }

    static var previews: some View {
        ThemeGallery {
            SpectrumBars(bands: sample)
                .frame(width: 420)

            // Dimmed, and empty. Both ship broken, because both are only on
            // screen when nobody is looking at them.
            SpectrumBars(bands: sample, isDimmed: true)
                .frame(width: 420)

            SpectrumBars(bands: [])
                .frame(width: 420)

            // The MIX mode: a response curve traced over the bars, in overlay
            // style — no plate or border of its own, so the bars' face and
            // scale show through underneath it.
            ZStack {
                SpectrumBars(bands: sample)
                ResponseCurve(
                    points: (0..<120).map {
                        let position = Double($0) / 119
                        return ResponseCurve.Point(
                            position: position, value: 8 * sin(position * .pi * 3)
                        )
                    },
                    range: -15...15,
                    isOverlay: true
                )
            }
            .frame(width: 420)
        }
    }
}

import SwiftUI

/// A row of vertical faders with legends underneath.
///
/// Built by hand rather than from `Slider` for two reasons: a slider cannot be
/// given a physical centre detent, and a themed skin needs to draw its own cap
/// and groove. The detent is the interesting part — a graphic EQ that cannot
/// be returned exactly to flat is useless, and hitting 0.0 on a continuous
/// drag is otherwise a matter of luck.
public struct FaderBank: View {
    @Environment(\.theme) private var theme

    public struct Band: Identifiable, Equatable, Sendable {
        public let id: Int
        /// Legend under the fader — "125", "16k".
        public let label: String
        public let value: Double
        /// Drawn differently when a band is a shelf rather than a peak.
        public let isShelf: Bool

        public init(id: Int, label: String, value: Double, isShelf: Bool = false) {
            self.id = id
            self.label = label
            self.value = value
            self.isShelf = isShelf
        }
    }

    private let bands: [Band]
    private let range: ClosedRange<Double>
    private let onChange: (Int, Double) -> Void

    /// Fraction of the travel within which the fader snaps to centre.
    private static let detentFraction = 0.04

    public init(
        bands: [Band],
        range: ClosedRange<Double>,
        onChange: @escaping (Int, Double) -> Void
    ) {
        self.bands = bands
        self.range = range
        self.onChange = onChange
    }

    public var body: some View {
        VStack(spacing: theme.metrics.tightSpacing) {
            ZStack(alignment: .top) {
                // One rule across the whole bank rather than a line inside each
                // groove. Per-fader lines drift by a pixel against each other
                // and against the caps, which reads as a drawing bug — and the
                // thing a graphic EQ most needs to show is which bands are
                // above and below flat.
                if theme.chrome.showsCentreDetent {
                    Rectangle()
                        .fill(theme.colors.panelBorder)
                        .frame(height: 1)
                        .offset(y: zeroLineOffset)
                }

                HStack(alignment: .bottom, spacing: theme.metrics.controlSpacing) {
                    ForEach(bands) { band in
                        fader(for: band)
                    }
                }
            }
            .frame(height: theme.metrics.faderHeight)

            HStack(alignment: .top, spacing: theme.metrics.controlSpacing) {
                ForEach(bands) { band in
                    Text(band.label)
                        // Every legend the same weight. Dimming the shelf bands
                        // made the outermost fader look like a stuck hover
                        // state rather than a deliberate distinction.
                        .foregroundStyle(theme.colors.labelSecondary)
                        .font(theme.typography.caption)
                        .frame(width: capWidth)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    /// Where flat sits, measured to the centre of a cap so the rule passes
    /// through the caps rather than near them.
    private var zeroLineOffset: CGFloat {
        let travel = theme.metrics.faderHeight - theme.metrics.faderCapHeight
        let centreFraction = normalised((range.lowerBound + range.upperBound) / 2)
        return travel * (1 - centreFraction) + theme.metrics.faderCapHeight / 2
    }

    private var capWidth: CGFloat { theme.metrics.knobDiameter / 2 }

    private func fader(for band: Band) -> some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let travel = max(height - theme.metrics.faderCapHeight, 1)
            let fraction = normalised(band.value)
            let capY = travel * (1 - fraction)

            ZStack(alignment: .top) {
                groove(height: height)

                // Always the nominal colour. Amber means peak, clip or
                // attention; a fader that has been moved is none of those.
                // Greying the ones at centre was worse still — at flat that is
                // every band, and a bank of grey caps reads as disabled.
                RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                    .fill(theme.colors.meterNominal)
                    .frame(height: theme.metrics.faderCapHeight)
                    .offset(y: capY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = min(max(drag.location.y - theme.metrics.faderCapHeight / 2, 0), travel)
                        let raw = 1 - (clamped / travel)
                        onChange(band.id, detented(value(from: raw)))
                    }
            )
        }
        .frame(width: capWidth, height: theme.metrics.faderHeight)
    }

    private func groove(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: theme.metrics.faderTrackWidth / 2)
            .fill(theme.colors.controlTrack)
            .frame(width: theme.metrics.faderTrackWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func normalised(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func value(from fraction: Double) -> Double {
        range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Snap to the centre of the range when close to it.
    ///
    /// Only when the theme says the control has a detent — a plain slider
    /// should not silently refuse to sit at −0.3 dB.
    private func detented(_ value: Double) -> Double {
        guard theme.chrome.showsCentreDetent else { return value }
        let centre = (range.lowerBound + range.upperBound) / 2
        let window = (range.upperBound - range.lowerBound) * Self.detentFraction
        return abs(value - centre) < window ? centre : value
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct FaderBank_Previews: PreviewProvider {
    static var previews: some View {
            ThemeGallery {
                FaderBank(
                    bands: [
                        FaderBank.Band(id: 0, label: "31", value: 6, isShelf: true),
                        FaderBank.Band(id: 1, label: "125", value: 0),
                        FaderBank.Band(id: 2, label: "1k", value: -4),
                        FaderBank.Band(id: 3, label: "16k", value: 9, isShelf: true)
                    ],
                    range: -12...12,
                    onChange: { _, _ in }
                )
            }
    }
}

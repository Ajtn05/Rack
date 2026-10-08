import SwiftUI

/// A stereo peak meter with hold markers.
///
/// Takes positions already scaled to 0…1 and does no ballistics of its own.
/// The decay, the hold time and the decibel mapping are decisions about
/// *metering*, which belong with the audio values, not with the drawing —
/// AppCore's `PeakMeter` owns them. This component's whole job is to be the
/// same shape under every skin.
public struct LevelMeter: View {
    @Environment(\.theme) private var theme

    /// One channel.
    public struct Channel: Equatable, Sendable {
        public let label: String
        /// 0…1, already dB-scaled.
        public let position: Double
        /// 0…1, the held peak.
        public let hold: Double

        public init(label: String, position: Double, hold: Double) {
            self.label = label
            self.position = position
            self.hold = hold
        }
    }

    private let channels: [Channel]
    private let hotThreshold: Double
    private let isDimmed: Bool

    /// - Parameter hotThreshold: where the bar changes colour, in the same
    ///   0…1 space. Defaults to the position of −6 dBFS on a −60 dB scale.
    /// - Parameter isDimmed: drawn in the idle colour rather than the lit
    ///   one — for a display that has gone quiet from disuse rather than
    ///   from silence. The position itself is still true; only the colour
    ///   says the meter is not being watched.
    public init(channels: [Channel], hotThreshold: Double = 0.9, isDimmed: Bool = false) {
        self.channels = channels
        self.hotThreshold = hotThreshold
        self.isDimmed = isDimmed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.tightSpacing / 2) {
            ForEach(channels, id: \.label) { channel in
                HStack(spacing: theme.metrics.tightSpacing) {
                    Text(channel.label)
                        .font(theme.typography.caption)
                        .foregroundStyle(theme.colors.labelSecondary)
                        .frame(width: 12, alignment: .leading)
                    bar(for: channel)
                }
            }
        }
    }

    private func bar(for channel: Channel) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.colors.controlTrack)

                Rectangle()
                    .fill(
                        isDimmed
                            ? theme.colors.controlIdle
                            : channel.position >= hotThreshold
                                ? theme.colors.meterHot
                                : theme.colors.meterNominal
                    )
                    .frame(width: width * clamp(channel.position))

                // Inset by its own width at the top of the scale, or a full
                // signal puts the tick past the end of the bar.
                let tickWidth: CGFloat = theme.chrome.borderWidth > 0 ? 2 : 1
                Rectangle()
                    .fill(isDimmed ? theme.colors.controlIdle : theme.colors.meterHold)
                    .frame(width: tickWidth)
                    .offset(
                        x: min(
                            max(0, width * clamp(channel.hold) - tickWidth / 2),
                            max(0, width - tickWidth)
                        )
                    )
                    .opacity(channel.hold > 0 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.chrome.cornerRadius / 2))
        }
        .frame(height: theme.metrics.meterHeight)
        // No implicit animation. The ballistics upstream are the only
        // smoothing wanted; SwiftUI adding its own on top reads as lag.
        .animation(nil, value: channel.position)
        .animation(nil, value: channel.hold)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct LevelMeter_Previews: PreviewProvider {
    static var previews: some View {
            ThemeGallery {
                LevelMeter(
                    channels: [
                        LevelMeter.Channel(label: "L", position: 0.62, hold: 0.78),
                        LevelMeter.Channel(label: "R", position: 0.95, hold: 0.97)
                    ]
                )
                .frame(width: 180)
            }
    }
}

import SwiftUI

/// A bipolar meter for phase correlation: −1…+1, filling from the center
/// rather than from an edge.
///
/// Deliberately not built on `LevelMeter` — that component fills from a
/// fixed edge and has no notion of a center reference, and retrofitting a
/// center-fill mode onto it would push one meter's need into a component
/// that has no other use for it. Same flat, undecorated shape as
/// `LevelMeter` — one consistent family under every skin — but its own
/// type, because what it draws is a genuinely different picture: not "how
/// loud", but "which way, and how far from neutral".
public struct PhaseMeter: View {
    @Environment(\.theme) private var theme

    /// 0…1, already mapped from the correlation coefficient — `0` is fully
    /// out of phase, `0.5` is unrelated (or silent), `1` is fully in phase.
    private let position: Double
    private let isDimmed: Bool

    /// - Parameter isDimmed: drawn in the idle colour rather than the lit
    ///   one, the same convention `LevelMeter` and `NeedleMeter` use for a
    ///   display that has gone quiet from disuse.
    public init(position: Double, isDimmed: Bool = false) {
        self.position = position
        self.isDimmed = isDimmed
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let center = width * 0.5
            let head = width * clamp(position)
            let tickWidth: CGFloat = theme.chrome.borderWidth > 0 ? 2 : 1

            ZStack(alignment: .leading) {
                Rectangle().fill(theme.colors.controlTrack)

                Rectangle()
                    .fill(isDimmed ? theme.colors.controlIdle : fillColor)
                    .frame(width: abs(head - center))
                    .offset(x: min(head, center))

                // The meter's own zero — unrelated channels, or nothing
                // playing at all. Drawn over the fill rather than under it,
                // so it stays visible even when the reading sits right on
                // top of center.
                Rectangle()
                    .fill(isDimmed ? theme.colors.controlIdle : theme.colors.panelBorder)
                    .frame(width: tickWidth)
                    .offset(x: center - tickWidth / 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.chrome.cornerRadius / 2))
        }
        .frame(height: theme.metrics.meterHeight)
        // No implicit animation — the ballistic upstream is the only
        // smoothing wanted, the same reasoning `LevelMeter` documents.
        .animation(nil, value: position)
    }

    /// Below center is negative correlation — the fault this meter exists
    /// to catch — drawn in the same warm colour a level meter's own hot
    /// zone uses. At or above center is unrelated-to-identical, which is
    /// never a fault, so it stays in the nominal colour all the way to +1.
    private var fillColor: Color {
        position < 0.5 ? theme.colors.meterHot : theme.colors.meterNominal
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct PhaseMeter_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            VStack(spacing: 12) {
                PhaseMeter(position: 1.0)
                PhaseMeter(position: 0.85)
                PhaseMeter(position: 0.5)
                PhaseMeter(position: 0.15)
                PhaseMeter(position: 0.0)
            }
            .frame(width: 180)
        }
    }
}

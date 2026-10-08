import SwiftUI

/// A horizontal fader.
///
/// The same idea as one column of `FaderBank` laid on its side, and it exists
/// for the same reason a mixing desk has both: a channel strip in a list wants
/// its level running along the row, not standing up in it.
///
/// Takes a value and a callback. It holds no state of its own beyond where a
/// drag began — which is deliberate: a control that remembers its own position
/// will eventually disagree with the thing it controls.
public struct LevelSlider: View {
    @Environment(\.theme) private var theme

    private let value: Double
    private let range: ClosedRange<Double>
    private let isEnabled: Bool
    private let onChange: (Double) -> Void

    public init(
        value: Double,
        range: ClosedRange<Double> = 0...1,
        isEnabled: Bool = true,
        onChange: @escaping (Double) -> Void
    ) {
        self.value = value
        self.range = range
        self.isEnabled = isEnabled
        self.onChange = onChange
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let cap = theme.metrics.faderCapHeight
            // The cap's centre travels between its own half-widths, so it never
            // hangs off either end of the groove.
            let travel = max(width - cap, 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.colors.controlTrack)
                    .frame(height: theme.metrics.faderTrackWidth)

                Capsule()
                    .fill(fillColour)
                    .frame(width: cap / 2 + travel * fraction, height: theme.metrics.faderTrackWidth)

                RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                    .fill(capColour)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                            .strokeBorder(
                                theme.colors.panelBorder,
                                lineWidth: max(theme.chrome.borderWidth, 1)
                            )
                    )
                    .frame(width: cap, height: cap)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, travel > 0 else { return }
                        // Absolute rather than relative: a horizontal fader in
                        // a list is grabbed at the point you want, the way a
                        // desk fader is, and the cap is too small to aim at.
                        let position = (drag.location.x - cap / 2) / travel
                        onChange(valueFor(min(max(position, 0), 1)))
                    }
            )
        }
        .frame(height: theme.metrics.faderCapHeight)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var fillColour: Color {
        isEnabled ? theme.colors.controlActive : theme.colors.controlIdle
    }

    private var capColour: Color {
        isEnabled ? theme.colors.controlActive : theme.colors.controlIdle
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private func valueFor(_ fraction: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }
}

/// A lit or unlit indicator lamp.
///
/// The smallest thing on the panel that says something: on real equipment a
/// channel that is passing signal has a lamp, and it is how you find the one
/// that is making the noise without reading anything.
public struct ActivityLamp: View {
    @Environment(\.theme) private var theme

    private let isOn: Bool

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        Circle()
            .fill(isOn ? theme.colors.meterNominal : theme.colors.controlTrack)
            .overlay(
                Circle()
                    .strokeBorder(
                        theme.colors.panelBorder,
                        lineWidth: max(theme.chrome.borderWidth, 1)
                    )
            )
            .frame(
                width: theme.metrics.tightSpacing * 2,
                height: theme.metrics.tightSpacing * 2
            )
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct LevelSlider_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            ForEach([0.0, 0.35, 1.0], id: \.self) { value in
                HStack {
                    ActivityLamp(isOn: value > 0)
                    LevelSlider(value: value) { _ in }
                        .frame(width: 160)
                }
            }

            // Disabled: an application whose own tap could not be built, whose
            // fader would be a lie if it moved.
            HStack {
                ActivityLamp(isOn: false)
                LevelSlider(value: 1, isEnabled: false) { _ in }
                    .frame(width: 160)
            }
        }
    }
}

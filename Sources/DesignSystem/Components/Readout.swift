import SwiftUI

/// A raw value's display convention — the handful of idioms every panel's
/// numeric readouts already followed by hand: a plain one-decimal number, one
/// that always carries its sign, a percentage, a whole number of
/// milliseconds, or a compression ratio.
public enum ReadoutFormat: Sendable {
    case decibels
    case signedDecibels
    case percent
    case milliseconds
    case ratio

    func string(for value: Double) -> String {
        switch self {
        case .decibels:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .signedDecibels:
            let text = value.formatted(.number.precision(.fractionLength(1)))
            return value > 0 ? "+\(text)" : text
        case .percent:
            return "\(Int((value * 100).rounded()))"
        case .milliseconds:
            return "\(Int(value.rounded()))"
        case .ratio:
            return "\(value.formatted(.number.precision(.fractionLength(1)))):1"
        }
    }
}

/// A fixed-width numeric display with a unit suffix.
///
/// Fixed width matters more than it sounds: a value that changes width as it
/// counts makes everything beside it twitch, and a meter surrounded by
/// twitching labels is unreadable. The width is reserved from `characterCount`
/// rather than measured from the current value.
///
/// A `.segmented` face draws the value on its own lit plate. It used to also
/// draw a dim `8` behind every digit, meaning to imitate the unlit segments a
/// fluorescent display shows for digits it is not currently using. That is
/// gone, and the reason is worth recording so nobody re-adds it:
///
/// A real unlit segment is a *shape* — one of seven bars, dark against the
/// glass. Setting the character `8` in the display font does not draw those
/// seven bars; it draws a dim number eight, and the eye reads a dim number
/// eight as a stuck digit rather than as an unlit cell. Doing it honestly
/// means rendering actual segment geometry, and that runs straight into what
/// this component is actually asked to show: `CTR`, `L 40`, `−∞`, `RUNNING`.
/// None of those decompose into seven segments, so a genuine implementation
/// would need a second, text path anyway — and a display that is segment-real
/// for `−4.2` and plain text for `CTR` is less coherent than one that is
/// honestly plain text throughout.
///
/// So the plate, the fixed width and the lit colour stay; the imitation does
/// not. `readoutDim` survives for the components that genuinely use it —
/// `ResponseCurve` draws its gridlines in it.
public struct Readout: View {
    @Environment(\.theme) private var theme

    private let value: String
    private let unit: String?
    private let characterCount: Int
    private let isEmphasised: Bool

    public init(
        _ value: String,
        unit: String? = nil,
        characterCount: Int = 5,
        isEmphasised: Bool = false
    ) {
        self.value = value
        self.unit = unit
        self.characterCount = characterCount
        self.isEmphasised = isEmphasised
    }

    /// Formats a raw value by `ReadoutFormat` convention instead of taking an
    /// already-formatted string — so a caller with a `Double` and a knob's
    /// own display convention does not need a formatter of its own.
    public init(
        _ value: Double,
        format: ReadoutFormat,
        unit: String? = nil,
        characterCount: Int = 5,
        isEmphasised: Bool = false
    ) {
        self.init(
            format.string(for: value), unit: unit,
            characterCount: characterCount, isEmphasised: isEmphasised
        )
    }

    /// The value with any trailing copy of the unit removed.
    ///
    /// Callers hand this component strings from formatters that often already
    /// carry a unit, and the suffix label then draws a second one — "−8.2 dB dB".
    /// Stripping here means neither caller nor component has to remember.
    private var cleanedValue: String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let unit, !unit.isEmpty, text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Never narrower than the value it has to show.
    private var width: Int { max(characterCount, cleanedValue.count) }

    private var paddedValue: String {
        String(repeating: " ", count: max(0, width - cleanedValue.count)) + cleanedValue
    }

    /// Real bloom, for a display style that actually emits light. A
    /// `.printed` or `.segmented` face never gets one here regardless of
    /// what `displayGlowRadius` happens to hold — glow is a property of
    /// *this* display style, not of any positive radius a theme might have
    /// left lying around for a component that does not exist yet.
    private var hasGlow: Bool {
        theme.chrome.displayStyle == .emissive && theme.metrics.displayGlowRadius > 0
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metrics.tightSpacing) {
            Text(paddedValue)
                .foregroundStyle(
                    isEmphasised
                        ? theme.colors.controlActive
                        : theme.colors.readoutForeground
                )
                .shadow(
                    color: hasGlow ? theme.colors.displayGlow : .clear,
                    radius: hasGlow ? theme.metrics.displayGlowRadius : 0
                )
                .font(theme.typography.readout)
                // Tabular figures, so a counting value does not resize and
                // twitch everything beside it.
                .monospacedDigit()
                .fixedSize()

            if let unit {
                Text(unit)
                    .font(theme.typography.readoutUnit)
                    .foregroundStyle(theme.colors.labelSecondary)
                    // A unit is one short token and never wraps. Squeezed by
                    // a narrow window "dB" broke onto its own line and the
                    // readout grew a second storey.
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, platePadding.horizontal)
        .padding(.vertical, platePadding.vertical)
        .background(readoutBackground)
    }

    /// How much glass shows around the value.
    ///
    /// A plate needs real margin: the value set on it is the largest type on
    /// the panel, and `tightSpacing` — which is calibrated for the gaps
    /// *between* small controls — left barely two points above and below a
    /// nineteen-point digit, so the numbers looked jammed against the top and
    /// bottom edges of their own window.
    ///
    /// A `.printed` face has no plate to pad, so it keeps the tighter figure:
    /// what would be margin there is just gap, and the grid around it is
    /// already spacing the column.
    private var platePadding: (horizontal: CGFloat, vertical: CGFloat) {
        let unit = theme.metrics.tightSpacing
        switch theme.chrome.displayStyle {
        case .printed:
            return (unit, unit / 2)
        case .segmented, .emissive:
            // Vertical is where the cramping actually was — digits jammed
            // against the top and bottom of their own glass. Horizontal gets
            // a much smaller lift: a readout sits in a fixed grid column, and
            // widening the plate as far as the vertical fix wanted pushed the
            // unit suffix past the column's edge and clipped "Hz" and "ms" in
            // Diagnostics.
            return (unit * 1.15, unit * 0.9)
        }
    }

    @ViewBuilder
    private var readoutBackground: some View {
        switch theme.chrome.displayStyle {
        case .segmented, .emissive:
            // Both sit behind their own piece of glass — they differ in
            // ghost digits versus bloom, not in whether there is a display
            // at all. `.printed` is the one with no glass of its own: ink on
            // the panel, showing the panel's own background through.
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .fill(theme.colors.readoutBackground)
        case .printed:
            Color.clear
        }
    }
}

/// A readout with a legend above it.
///
/// Two unlabelled numbers side by side are two numbers nobody can identify.
public struct LabelledReadout: View {
    @Environment(\.theme) private var theme

    private let title: String
    private let readout: Readout

    public init(_ title: String, _ readout: Readout) {
        self.title = title
        self.readout = readout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(theme.typography.caption)
                .foregroundStyle(theme.colors.labelSecondary)
            readout
        }
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct Readout_Previews: PreviewProvider {
    static var previews: some View {
        ThemeGallery {
            // The cases that broke: negative, short, over-long, a value that
            // already carries its unit, and a value with no digits at all.
            LabelledReadout("Volume", Readout("−45.4", unit: "dB"))
            LabelledReadout("Peak", Readout("−8.2 dB", unit: "dB"))
            LabelledReadout("Rate", Readout("96000", unit: "Hz", characterCount: 6))
            LabelledReadout("Balance", Readout("CTR", characterCount: 6))
            LabelledReadout("Trim", Readout("0", characterCount: 4, isEmphasised: true))
        }
    }
}

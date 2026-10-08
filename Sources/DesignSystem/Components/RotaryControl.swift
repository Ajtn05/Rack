import SwiftUI

/// A knob that also accepts a vertical drag.
///
/// The vertical drag is not a nicety. Rotating a knob with a trackpad means
/// tracing an arc with two fingers, which is genuinely unpleasant and
/// imprecise; every audio application that ships knobs also accepts a straight
/// drag, and this one does the same. The circle is what it looks like, not how
/// it is operated.
public struct RotaryControl: View {
    @Environment(\.theme) private var theme

    private let label: String
    private let value: Double
    private let range: ClosedRange<Double>
    private let detentAtCentre: Bool
    private let size: Size
    private let variant: Variant
    private let labelPlacement: LabelPlacement
    private let onChange: (Double) -> Void

    /// Where this control's legend goes.
    public enum LabelPlacement: Sendable {
        /// Under the knob. The default, and right for a control standing alone.
        case below

        /// Nowhere — the caller is laying the legend out itself.
        ///
        /// For a row of knobs of different sizes. With the legend attached, a
        /// large knob and a small one produce two stacks of different heights,
        /// and no alignment available to the row can put both the knobs on one
        /// centre line *and* the legends on another. Handing the legend back to
        /// the caller lets it put each in its own row and align them properly.
        case none
    }

    /// Relative importance. On real equipment volume is physically the largest
    /// control on the face, and that is how you find it without looking.
    public enum Size: Sendable {
        case standard
        case large
        case small

        var scale: CGFloat {
            switch self {
            case .small: 0.7
            case .standard: 1
            case .large: 1.45
            }
        }
    }

    /// Which functional group this knob belongs to.
    ///
    /// Not styling for its own sake: console hardware colour-codes caps so
    /// you can tell a level control from a shaping one before reading a
    /// legend. A theme that does not distinguish them draws both the same,
    /// so a caller can always pass the honest value.
    public enum Variant: Sendable {
        /// Level and routing — volume, balance, trim.
        case primary
        /// Shaping — tone, boost, effect depth.
        case secondary
    }

    /// Points of vertical travel for the full range. Roughly a hand's span,
    /// which makes fine adjustment possible without the pointer leaving the
    /// window.
    private static let dragTravel: Double = 160

    /// Sweep of the indicator, leaving a gap at the bottom so the ends of the
    /// range are visually distinct.
    private static let sweepDegrees: Double = 280

    /// - Parameter detentAtCentre: also makes the control **bipolar** — its
    ///   arc is drawn from twelve o'clock outward in whichever direction the
    ///   value has gone, rather than filling from the start of the range. A
    ///   balance control that fills like a volume control tells you nothing
    ///   about which way it is leaning.
    public init(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        detentAtCentre: Bool = false,
        size: Size = .standard,
        variant: Variant = .primary,
        labelPlacement: LabelPlacement = .below,
        onChange: @escaping (Double) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.detentAtCentre = detentAtCentre
        self.size = size
        self.variant = variant
        self.labelPlacement = labelPlacement
        self.onChange = onChange
    }

    private var diameter: CGFloat { theme.metrics.knobDiameter * size.scale }

    /// Bipolar controls read outward from the centre; unipolar ones fill from
    /// the start.
    private var isBipolar: Bool { detentAtCentre }

    @State private var dragStartValue: Double?

    public var body: some View {
        switch labelPlacement {
        case .below:
            VStack(spacing: theme.metrics.tightSpacing) {
                knob
                Text(label.uppercased())
                    .font(theme.typography.caption)
                    .foregroundStyle(theme.colors.labelSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .none:
            knob
        }
    }

    private var knob: some View {
        // The body of the knob: everything that does *not* turn. Only the
        // indicator rotates, below — which is the whole trick. A real knob's
        // cap turns but the light on it does not follow, so its highlight and
        // its cast shadow stay put; rotating the shading with the value is
        // the single most common way this effect gets built backwards, and
        // it reads instantly as wrong even to someone who cannot say why.
        ZStack {
            // The skirt: the fixed collar a knob sits in, with tick marks
            // around the travel. Drawn under the cap so the cap's own shadow
            // falls onto it.
            if hasSkirt {
                skirt
            }

            // The cap: face, bevel and rim as one stack, so the bevel is an
            // overlay *on the face* rather than a separate sibling.
            //
            // It was a sibling, briefly, and the bug is worth recording: a
            // bare `Circle()` in a `ZStack` is not an empty placeholder to
            // hang an overlay on — with no `.fill` it renders filled with the
            // default foreground style, so it painted a pale disc straight
            // over every knob face on every dark theme.
            Circle()
                .fill(knobFaceStyle)
                .bevelled(Circle(), theme.knobBevel)
                .overlay(
                    Circle().strokeBorder(theme.colors.knobRing, lineWidth: ringWidth)
                )
                // The cap stands proud of its skirt, lit by the window's own
                // light source rather than by an offset chosen here.
                .litShadow(
                    height: theme.chrome.knobStyle == .raised ? diameter * 0.06 : 0,
                    lighting: theme.lighting,
                    color: theme.colors.panelShadow
                )
                .padding(capInset)

            // The arc. A bipolar control draws from top-centre outward in the
            // direction it has moved; a unipolar one fills from its start.
            //
            // Inset inside the border rather than stroked on the knob's own
            // radius. A stroke straddles the path it is drawn on, so on the
            // full-radius circle half the arc's width fell outside the face —
            // it read as a rim that had come loose rather than as a value.
            //
            // Drawn only when it has a length. `lineCap: .round` paints a dot
            // for a zero-length trim, so a knob wound fully down showed a mark
            // at its minimum, and a balance control sitting dead centre showed
            // one at twelve o'clock — both indistinguishable from a small
            // reading that was not there.
            if hasArc {
                Circle()
                    .inset(by: arcInset + capInset)
                    .trim(from: arcRange.lowerBound, to: arcRange.upperBound)
                    .stroke(
                        theme.colors.knobArc,
                        style: StrokeStyle(lineWidth: theme.metrics.traceWidth, lineCap: .round)
                    )
                    // Puts trim 0 — which SwiftUI starts at three o'clock —
                    // onto the pointer's own zero, at the bottom of the sweep.
                    .rotationEffect(.degrees(90 + (360 - Self.sweepDegrees) / 2))
            }

            // The indicator — and *only* the indicator — turns with the
            // value. Everything above it stays where the light put it.
            indicator
                .rotationEffect(.degrees(-Self.sweepDegrees / 2 + fraction * Self.sweepDegrees))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // Anchored to where the drag began rather than to the
                    // pointer's absolute position, so grabbing a knob never
                    // makes it jump before it moves.
                    let start = dragStartValue ?? value
                    if dragStartValue == nil { dragStartValue = value }

                    let span = range.upperBound - range.lowerBound
                    let delta = -drag.translation.height / Self.dragTravel * span
                    onChange(detented(min(max(start + delta, range.lowerBound), range.upperBound)))
                }
                .onEnded { _ in dragStartValue = nil }
        )
    }

    /// The knob cap's own surface, from the theme's material rather than a
    /// flat fill — brushed, moulded, anodised, whatever the theme says the
    /// part is made of.
    private var knobFaceStyle: some ShapeStyle {
        // `MaterialSurface` is a View, not a ShapeStyle, so a textured cap is
        // drawn as a masked surface rather than as a fill. Flat is the common
        // case and stays a plain fill, which costs nothing.
        capMaterial.baseColor
    }

    /// The cap's material, honouring the theme's colour-coding if it has any.
    /// A theme with no alternate falls back to its one knob material, so a
    /// caller never has to know whether the distinction exists.
    private var capMaterial: ThemeMaterial {
        switch variant {
        case .primary: theme.knobMaterial
        case .secondary: theme.knobAlternateMaterial ?? theme.knobMaterial
        }
    }

    /// A raised knob's ring reads as a trim ring — brass, chrome, whatever
    /// the theme's `knobRing` is — rather than the hairline edge a flush
    /// knob is content with.
    private var ringWidth: CGFloat {
        let hairline = max(theme.chrome.borderWidth, 1)
        return theme.chrome.knobStyle == .raised ? hairline * 2.5 : hairline
    }

    /// How far the cap sits inside the control's bounds, leaving room for the
    /// skirt around it. No skirt means the cap is the whole knob.
    private var capInset: CGFloat {
        hasSkirt ? diameter * 0.11 : 0
    }

    /// Whether this theme's knobs have a machined collar with tick marks.
    /// Tied to `knobStyle`: a flush knob is a flat disc with nothing around
    /// it, and hanging a skirt on one would contradict what flush means.
    private var hasSkirt: Bool { theme.chrome.knobStyle == .raised }

    /// The fixed collar the cap turns inside, with tick marks around the
    /// travel. Part of the panel, not part of the knob — so it never rotates,
    /// and the cap's shadow falls onto it.
    private var skirt: some View {
        let tickCount = 11
        return ZStack {
            Circle().fill(theme.colors.panelShadow.opacity(0.18))

            ForEach(0..<tickCount, id: \.self) { index in
                let t = Double(index) / Double(tickCount - 1)
                Capsule()
                    .fill(theme.colors.labelSecondary)
                    .frame(width: max(diameter * 0.018, 1), height: diameter * 0.07)
                    .offset(y: -diameter * 0.455)
                    .rotationEffect(
                        .degrees(-Self.sweepDegrees / 2 + t * Self.sweepDegrees)
                    )
            }
        }
    }

    /// The mark that says where the knob is pointing.
    @ViewBuilder
    private var indicator: some View {
        switch theme.chrome.knobIndicatorStyle {
        case .line:
            Capsule()
                .fill(theme.colors.knobIndicator)
                .frame(width: max(diameter * 0.045, 2), height: diameter * 0.3)
                .offset(y: -diameter * 0.20)
        case .dot:
            Circle()
                .fill(theme.colors.knobIndicator)
                .frame(width: diameter * 0.10, height: diameter * 0.10)
                .offset(y: -diameter * 0.28)
        case .notch:
            // A cut into the cap's edge rather than a mark on its face: dark
            // side lit from the window's own source, so it reads as removed
            // material rather than as paint.
            Capsule()
                .fill(theme.colors.panelShadow)
                .frame(width: max(diameter * 0.07, 2), height: diameter * 0.16)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            theme.colors.panelHighlight.opacity(0.5),
                            lineWidth: max(theme.chrome.borderWidth, 1) * 0.6
                        )
                )
                .offset(y: -diameter * 0.33)
        }
    }

    /// How far inside the knob's edge the arc sits: clear of the border, and
    /// then half the arc's own width, so its outer edge lands on the face.
    private var arcInset: CGFloat {
        max(theme.chrome.borderWidth, 1) + theme.metrics.traceWidth / 2
    }

    /// Whether the arc has any length worth drawing. Below this it is a dot.
    private var hasArc: Bool {
        arcRange.upperBound - arcRange.lowerBound > 0.001
    }

    /// Where the arc starts and ends, as fractions of a full turn.
    private var arcRange: ClosedRange<CGFloat> {
        let sweep = CGFloat(Self.sweepDegrees / 360)
        let position = CGFloat(fraction) * sweep
        guard isBipolar else { return 0...position }
        let centre = sweep / 2
        return position < centre ? position...centre : centre...position
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func detented(_ value: Double) -> Double {
        guard detentAtCentre, theme.chrome.showsCentreDetent else { return value }
        let centre = (range.lowerBound + range.upperBound) / 2
        let window = (range.upperBound - range.lowerBound) * 0.03
        return abs(value - centre) < window ? centre : value
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct RotaryControl_Previews: PreviewProvider {
    static var previews: some View {
            ThemeGallery {
                HStack(alignment: .bottom) {
                    RotaryControl(
                        label: "Volume", value: 0.7, range: 0...1, size: .large
                    ) { _ in }
                    RotaryControl(
                        label: "Balance L", value: -0.6, range: -1...1,
                        detentAtCentre: true
                    ) { _ in }
                    RotaryControl(
                        label: "Balance R", value: 0.6, range: -1...1,
                        detentAtCentre: true
                    ) { _ in }
                    RotaryControl(
                        label: "Preamp", value: 0, range: -12...12,
                        detentAtCentre: true, size: .small
                    ) { _ in }
                }
            }
    }
}

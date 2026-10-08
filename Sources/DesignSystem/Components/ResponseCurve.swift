import SwiftUI

/// A line plotted on a bounded pair of axes, with gridlines and rules.
///
/// Deliberately ignorant of what is being plotted. Every point arrives with its
/// horizontal place already worked out as a fraction of the width, so whatever
/// mapping the caller wanted — logarithmic, linear, something else entirely —
/// happened before it got here. That is why nothing in this file names a
/// frequency, a decibel or a filter: it is a component that draws numbers, and
/// it stays one.
///
/// The same shape under every skin: a plot face, faint gridlines, a brighter
/// datum, and one trace over the top.
public struct ResponseCurve: View {
    @Environment(\.theme) private var theme

    /// One sample of the line.
    public struct Point: Equatable, Sendable {
        /// 0 at the left edge, 1 at the right.
        public let position: Double

        /// In the same units as `range`.
        public let value: Double

        public init(position: Double, value: Double) {
            self.position = position
            self.value = value
        }
    }

    /// A vertical rule, optionally captioned along the bottom edge.
    public struct Gridline: Equatable, Sendable {
        public let position: Double
        public let label: String?

        public init(position: Double, label: String? = nil) {
            self.position = position
            self.label = label
        }
    }

    /// A horizontal rule at `value`, optionally captioned at the left edge.
    public struct Rule: Equatable, Sendable {
        public let value: Double
        public let label: String?

        /// The datum. Drawn brighter than the others, because "no change" is
        /// the line every other part of the plot is read against, and a plot
        /// whose zero is as faint as its gridlines has to be counted rather
        /// than glanced at.
        public let isEmphasised: Bool

        public init(value: Double, label: String? = nil, isEmphasised: Bool = false) {
            self.value = value
            self.label = label
            self.isEmphasised = isEmphasised
        }
    }

    private let points: [Point]
    private let range: ClosedRange<Double>
    private let gridlines: [Gridline]
    private let rules: [Rule]
    private let isDimmed: Bool
    private let isOverlay: Bool

    /// - Parameter isDimmed: the line is drawn in the idle colour rather than
    ///   the lit one. For when the plot is still true but nothing is acting on
    ///   it — a display that goes blank in that state says less than one that
    ///   shows what it *would* do.
    /// - Parameter isOverlay: draws the trace alone — no plate, no border —
    ///   so this can sit in a `ZStack` on top of another display (a spectrum)
    ///   rather than in a plot of its own. The caller decides what, if
    ///   anything, else is drawn; passing gridlines or rules here as well
    ///   would draw a second axis over whatever the layer underneath already
    ///   has.
    public init(
        points: [Point],
        range: ClosedRange<Double>,
        gridlines: [Gridline] = [],
        rules: [Rule] = [],
        isDimmed: Bool = false,
        isOverlay: Bool = false
    ) {
        self.points = points
        self.range = range
        self.gridlines = gridlines
        self.rules = rules
        self.isDimmed = isDimmed
        self.isOverlay = isOverlay
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                    ruleView(rule, in: size)
                }
                ForEach(Array(gridlines.enumerated()), id: \.offset) { _, gridline in
                    gridlineView(gridline, in: size)
                }
                trace(in: size)
                    .stroke(
                        isDimmed ? theme.colors.controlIdle : theme.colors.readoutForeground,
                        style: StrokeStyle(
                            lineWidth: theme.metrics.traceWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    // Clipped rather than clamped. A curve that runs off the
                    // top of the plot has run off the top of the plot, and
                    // flattening it against the edge would draw a shelf that
                    // is not there.
                    //
                    // Only the trace. Clipping the whole view took the legends
                    // with it and cut the outermost one in half.
                    .clipShape(RoundedRectangle(cornerRadius: theme.chrome.cornerRadius))
            }
        }
        .frame(height: theme.metrics.graphHeight)
        .background(plate)
        .overlay(border)
    }

    // MARK: - Pieces

    /// The plot's own face — skipped entirely in overlay mode, where the view
    /// underneath (a `SpectrumBars`, so far) already draws one and a second
    /// would just paint over it.
    @ViewBuilder
    private var plate: some View {
        if !isOverlay {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .fill(theme.colors.readoutBackground)
        }
    }

    @ViewBuilder
    private var border: some View {
        if !isOverlay, theme.chrome.borderWidth > 0 {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .strokeBorder(theme.colors.panelBorder, lineWidth: theme.chrome.borderWidth)
        }
    }

    private func gridlineView(_ gridline: Gridline, in size: CGSize) -> some View {
        let x = self.x(gridline.position, in: size)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(theme.colors.readoutDim, lineWidth: hairline)

            if let label = gridline.label {
                legend(label)
                    // A label on the outermost gridline is centred on the edge
                    // of the plot, so half of it hangs outside — which is how
                    // the top of the range lost its right-hand half. Pinned to
                    // the inside of whichever edge it belongs to instead, and
                    // centred only when it is safely in the middle.
                    .frame(width: size.width, alignment: edgeAlignment(gridline.position))
                    .padding(.horizontal, theme.metrics.tightSpacing)
                    .position(
                        x: isNearEdge(gridline.position) ? size.width / 2 : x,
                        y: size.height - theme.metrics.tightSpacing
                    )
            }
        }
    }

    private func ruleView(_ rule: Rule, in size: CGSize) -> some View {
        let y = self.y(rule.value, in: size)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(
                rule.isEmphasised ? theme.colors.labelSecondary : theme.colors.readoutDim,
                lineWidth: hairline
            )

            if let label = rule.label {
                legend(label)
                    .padding(.leading, theme.metrics.tightSpacing)
                    // A full-width frame centred on the plot, with the text
                    // pinned to its leading edge: the only way to place a label
                    // against an edge without knowing how wide it renders.
                    .frame(width: size.width, alignment: .leading)
                    .position(x: size.width / 2, y: y - theme.metrics.tightSpacing)
            }
        }
    }

    private func trace(in size: CGSize) -> Path {
        Path { path in
            var started = false
            for point in points {
                let location = CGPoint(
                    x: x(point.position, in: size),
                    y: y(point.value, in: size)
                )
                guard location.x.isFinite, location.y.isFinite else { continue }
                if started {
                    path.addLine(to: location)
                } else {
                    path.move(to: location)
                    started = true
                }
            }
        }
    }

    // MARK: - Geometry

    /// A legend on the plot. One line, always, at its natural width.
    ///
    /// `lineLimit` and `fixedSize` together are what stop a narrow plot from
    /// breaking `+10` across two lines and stacking the halves — which turns a
    /// legend into something that reads as a rendering fault.
    private func legend(_ text: String) -> some View {
        Text(text)
            .font(theme.typography.caption)
            .foregroundStyle(theme.colors.labelSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// How close to an edge a gridline has to be before its label is pinned
    /// inside rather than centred on it.
    private static let edgeThreshold: Double = 0.06

    private func isNearEdge(_ position: Double) -> Bool {
        position < Self.edgeThreshold || position > 1 - Self.edgeThreshold
    }

    private func edgeAlignment(_ position: Double) -> Alignment {
        if position < Self.edgeThreshold { return .leading }
        if position > 1 - Self.edgeThreshold { return .trailing }
        return .center
    }

    /// The thinnest line that still draws. Borderless skins set
    /// `chrome.borderWidth` to zero, and a gridline of zero width is not a
    /// gridline.
    private var hairline: CGFloat { max(theme.chrome.borderWidth, 1) }

    private func x(_ position: Double, in size: CGSize) -> CGFloat {
        size.width * CGFloat(min(max(position, 0), 1))
    }

    private func y(_ value: Double, in size: CGSize) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return size.height / 2 }
        // Held to one plot-height either side of the range. Far enough out to
        // be clipped away, near enough that a value pinned to a floor does not
        // hand the rasteriser a coordinate in the millions.
        let bounded = min(max(value, range.lowerBound - span), range.upperBound + span)
        let fraction = (bounded - range.lowerBound) / span
        return size.height * CGFloat(1 - fraction)
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct ResponseCurve_Previews: PreviewProvider {
    /// A shape with something happening at both ends and in the middle, so a
    /// skin that gets the vertical mapping backwards is obvious on sight.
    static var sample: [ResponseCurve.Point] {
        (0..<120).map { index in
            let position = Double(index) / 119
            let value = 9 * sin(position * .pi * 2) - 4 * cos(position * .pi * 5)
            return ResponseCurve.Point(position: position, value: value)
        }
    }

    static var gridlines: [ResponseCurve.Gridline] {
        [
            ResponseCurve.Gridline(position: 1.0 / 3, label: "100"),
            ResponseCurve.Gridline(position: 2.0 / 3, label: "1k"),
            ResponseCurve.Gridline(position: 1, label: "10k")
        ]
    }

    static var rules: [ResponseCurve.Rule] {
        [
            ResponseCurve.Rule(value: 10, label: "+10"),
            ResponseCurve.Rule(value: 0, label: "0", isEmphasised: true),
            ResponseCurve.Rule(value: -10, label: "−10")
        ]
    }

    static var previews: some View {
        ThemeGallery {
            // Lit and dimmed, because the dimmed state is the one that ships
            // broken: it is only on screen when nobody is looking at it.
            ResponseCurve(
                points: sample, range: -15...15,
                gridlines: gridlines, rules: rules
            )
            .frame(width: 260)

            ResponseCurve(
                points: sample, range: -15...15,
                gridlines: gridlines, rules: rules, isDimmed: true
            )
            .frame(width: 260)

            // Nothing to draw. The face and its scale still have to appear.
            ResponseCurve(points: [], range: -15...15, gridlines: gridlines, rules: rules)
                .frame(width: 260)
        }
    }
}

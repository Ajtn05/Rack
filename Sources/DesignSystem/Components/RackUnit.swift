import SwiftUI

/// What a screen hands `RackUnit` to make its own header a drag source for
/// reordering, without every panel having to thread the value through its own
/// initialiser. `nil` means the header drags like plain text, which is to say
/// not at all.
///
/// An environment key rather than an init parameter because `RackUnit` is
/// wrapped by ten separate panel views, none of which otherwise have any
/// reason to know that panels can be reordered — that is a screen-level
/// concern, and the environment is what lets a screen reach through a layer
/// it does not own without changing that layer's public surface.
private struct RackUnitDragPayloadKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    public var rackUnitDragPayload: String? {
        get { self[RackUnitDragPayloadKey.self] }
        set { self[RackUnitDragPayloadKey.self] = newValue }
    }
}

/// Lets a screen give every `RackUnit` a "Full Width" switch in its own
/// header, the same way `rackUnitDragPayload` gives it a drag handle — an
/// environment value rather than an init parameter, for the same reason: the
/// ten panel views wrapping `RackUnit` have no reason to know a screen lets
/// their width be toggled.
public struct RackUnitWidthToggle: Sendable {
    public let isFullWidth: Bool
    // A global-actor-isolated closure is itself `Sendable` — invoking it from
    // any thread just hops to the main actor rather than running unsafely —
    // which is what lets this whole struct be `Sendable` while still wrapping
    // a plain closure that calls back into `@MainActor` state like
    // `EngineController`.
    public let toggle: @MainActor () -> Void

    public init(isFullWidth: Bool, toggle: @escaping @MainActor () -> Void) {
        self.isFullWidth = isFullWidth
        self.toggle = toggle
    }
}

private struct RackUnitWidthToggleKey: EnvironmentKey {
    static let defaultValue: RackUnitWidthToggle? = nil
}

extension EnvironmentValues {
    public var rackUnitWidthToggle: RackUnitWidthToggle? {
        get { self[RackUnitWidthToggleKey.self] }
        set { self[RackUnitWidthToggleKey.self] = newValue }
    }
}

/// The same idea as `RackUnitWidthToggle`, for the other axis: whether a
/// panel stretches to match the tallest panel in its own row rather than
/// stopping at its own natural height.
///
/// Only meaningful when a panel is tiling beside another — a full-width
/// panel is already the only thing in its row, so there is nothing for it to
/// match — but harmless to set regardless, since `RackTileLayout` already
/// proposes every panel in a row its row's own height and this only decides
/// whether that panel *takes* the offer.
public struct RackUnitHeightToggle: Sendable {
    public let isFullHeight: Bool
    public let toggle: @MainActor () -> Void

    public init(isFullHeight: Bool, toggle: @escaping @MainActor () -> Void) {
        self.isFullHeight = isFullHeight
        self.toggle = toggle
    }
}

private struct RackUnitHeightToggleKey: EnvironmentKey {
    static let defaultValue: RackUnitHeightToggle? = nil
}

extension EnvironmentValues {
    public var rackUnitHeightToggle: RackUnitHeightToggle? {
        get { self[RackUnitHeightToggleKey.self] }
        set { self[RackUnitHeightToggleKey.self] = newValue }
    }
}

/// A titled panel with an optional status line — one component in the stack.
///
/// Whether that reads as a bolted-in box or as a region of one continuous
/// surface is `chrome.panelStyle`, not something a screen decides. Screens say
/// *what* is grouped; the theme says how a group looks.
public struct RackUnit<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.rackUnitDragPayload) private var dragPayload
    @Environment(\.rackUnitWidthToggle) private var widthToggle
    @Environment(\.rackUnitHeightToggle) private var heightToggle

    private let title: String
    private let status: String?
    private let accessory: AnyView?
    private let content: Content

    public init(
        _ title: String,
        status: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.status = status
        self.accessory = nil
        self.content = content()
    }

    public init<Accessory: View>(
        _ title: String,
        status: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.status = status
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.tightSpacing) {
            header
            content
        }
        .padding(theme.metrics.panelPadding)
        // Width always fills whatever column it was given. Height only does
        // the same when the toggle asks for it — otherwise this stops at its
        // own content's height exactly as it always has, leaving a shorter
        // row-mate's own row height unclaimed rather than reaching for it.
        .frame(
            maxWidth: .infinity,
            maxHeight: isFullHeight ? .infinity : nil,
            alignment: .topLeading
        )
        // The drop shadow goes on the *background layer*, not on the finished
        // panel, and that placement is a battery decision rather than a visual
        // one — the two look identical.
        //
        // `.shadow` applied to a composited view makes SwiftUI render the whole
        // subtree offscreen and blur it, and redo that whenever any part of the
        // subtree changes. Hung on the outside of the panel it covered the
        // header, the knobs, the meters and the analyzer, so every meter tick —
        // thirty a second — forced a full-panel offscreen Gaussian blur of
        // content that was not casting the shadow in the first place.
        //
        // A panel's silhouette is `RoundedRectangle(cornerRadius:)` and nothing
        // else: `background` is an opaque material clipped to exactly that
        // shape, and every overlay above (screws, border, relief, bevel) draws
        // inside it. So the cast shadow is a function of the panel's *size*,
        // which changes when the window is resized and at no other time. Behind
        // the background it rasterises once and is reused.
        .background(shadowed(background))
        .overlay(screws)
        .overlay(border)
        .overlay(relief)
        // The panel's own bevel, direction taken from the window's single
        // light source rather than from anything decided here.
        .bevelled(
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius),
            theme.panelBevel
        )
    }

    /// The background, carrying the panel's drop shadow when the theme casts
    /// one at all.
    ///
    /// Applied conditionally rather than with a clear colour: a `.shadow` whose
    /// colour is `.clear` still asks for the offscreen pass that produces
    /// nothing, and eight of the nine themes are `.flat` or `.inset` and cast
    /// no panel shadow whatsoever.
    @ViewBuilder
    private func shadowed(_ layer: some View) -> some View {
        if theme.chrome.panelRelief == .raised {
            layer.shadow(
                color: theme.colors.panelShadow,
                radius: reliefShadowRadius,
                x: 0,
                y: reliefShadowRadius * 0.5
            )
        } else {
            layer
        }
    }

    private var isFullHeight: Bool { heightToggle?.isFullHeight ?? false }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metrics.tightSpacing) {
            dragRegion
            accessory
            heightToggleButton
            widthToggleButton
        }
    }

    /// The title, its status line, and the empty header space after them —
    /// everything except the accessory and the width toggle, which need
    /// their own taps to reach as a click rather than as the first pixel of
    /// a drag that was never wanted.
    ///
    /// Wider than just the title text on purpose: a hit box exactly the size
    /// of a legend is easy to miss entirely, and this is the one part of the
    /// panel with nothing else underneath it to protect — no knob, no fader,
    /// no chip — so there is no reason to keep the drag handle any smaller
    /// than "most of the header."
    private var dragRegion: some View {
        let row = HStack(spacing: 0) {
            titleBlock
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // The title bar is the drag handle, the same way a real window is
        // moved by its own title bar rather than by any point on its face —
        // so a knob or a fader underneath keeps its own drag gesture instead
        // of losing the first pixel of every move to a reorder that was never
        // wanted.
        return Group {
            if let dragPayload {
                row.contentShape(Rectangle()).draggable(dragPayload)
            } else {
                row
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(theme.typography.unitTitle)
                // Silkscreened panel legends are widely tracked. A theme
                // with no such tradition sets this to nothing.
                .tracking(theme.chrome.panelStyle == .separated ? 1.5 : 0)
                // The unit's name is the largest legend on its panel and
                // the one where an engraved treatment reads most clearly.
                .engraved(theme.engraving)

            if let status {
                Text(status)
                    .font(theme.typography.unitStatus)
                    .foregroundStyle(theme.colors.labelSecondary)
            }
        }
    }

    /// A small icon switch for whether this unit takes a full row or tiles
    /// beside whatever else fits. Present only when a screen has wired one up
    /// — most previews and any future host that never sets
    /// `rackUnitWidthToggle` draw the header exactly as before.
    ///
    /// Drawn rather than a labelled chip: the icon *is* the two states it
    /// switches between — one bar standing for the panel spanning its row,
    /// two standing for it sharing one — so reading it needs no legend, and
    /// it costs the header a corner rather than a whole cap-and-caption
    /// control's width.
    @ViewBuilder
    private var widthToggleButton: some View {
        if let widthToggle {
            Button {
                widthToggle.toggle()
            } label: {
                widthGlyph(isFullWidth: widthToggle.isFullWidth)
                    .frame(width: widthToggleDiameter, height: widthToggleDiameter)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(widthToggle.isFullWidth ? "Full width" : "Tiles beside other panels")
        }
    }

    private var widthToggleDiameter: CGFloat { theme.metrics.tightSpacing * 2.2 }

    private func widthGlyph(isFullWidth: Bool) -> some View {
        let colour = isFullWidth ? theme.colors.controlActive : theme.colors.labelSecondary
        let barHeight = theme.metrics.tightSpacing * 0.9
        return HStack(spacing: isFullWidth ? 0 : theme.metrics.tightSpacing * 0.35) {
            RoundedRectangle(cornerRadius: 1).fill(colour)
            if !isFullWidth {
                RoundedRectangle(cornerRadius: 1).fill(colour)
            }
        }
        .frame(height: barHeight)
    }

    /// A small icon switch for whether this unit stretches to match the
    /// tallest panel beside it. The vertical twin of `widthToggleButton`: the
    /// same glyph, turned 90 degrees, so the pair reads as one control
    /// answering "how wide" and one answering "how tall" rather than as two
    /// unrelated buttons.
    @ViewBuilder
    private var heightToggleButton: some View {
        if let heightToggle {
            Button {
                heightToggle.toggle()
            } label: {
                heightGlyph(isFullHeight: heightToggle.isFullHeight)
                    .frame(width: widthToggleDiameter, height: widthToggleDiameter)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(heightToggle.isFullHeight ? "Matches the row's height" : "Its own natural height")
        }
    }

    private func heightGlyph(isFullHeight: Bool) -> some View {
        let colour = isFullHeight ? theme.colors.controlActive : theme.colors.labelSecondary
        let barWidth = theme.metrics.tightSpacing * 0.9
        return VStack(spacing: isFullHeight ? 0 : theme.metrics.tightSpacing * 0.35) {
            RoundedRectangle(cornerRadius: 1).fill(colour)
            if !isFullHeight {
                RoundedRectangle(cornerRadius: 1).fill(colour)
            }
        }
        .frame(width: barWidth)
    }

    @ViewBuilder
    private var background: some View {
        switch theme.chrome.panelStyle {
        case .separated:
            // The panel's own material — brushed, painted, moulded, whatever
            // the theme says the face is made of. A `.flat` material is a
            // plain fill and costs exactly what it did before the material
            // system existed.
            MaterialSurface(theme.panelMaterial)
                .overlay(alignment: .top) { topStrip }
                .overlay(alignment: .bottom) { seam }
                .clipShape(RoundedRectangle(cornerRadius: theme.chrome.cornerRadius))
        case .continuous:
            // Nothing. The window's own surface shows through, which is what
            // makes the stack read as one piece.
            Color.clear
        }
    }

    /// A brushed extrusion capping the panel, for themes whose faceplates are
    /// two pieces rather than one.
    @ViewBuilder
    private var topStrip: some View {
        if let strip = theme.hardware.topStrip {
            MaterialSurface(strip)
                .frame(height: theme.metrics.panelPadding * 0.5)
                .overlay(alignment: .bottom) {
                    // The joint where the two pieces meet.
                    Rectangle()
                        .fill(theme.colors.panelShadow.opacity(0.55))
                        .frame(height: max(theme.chrome.borderWidth, 1))
                }
                .allowsHitTesting(false)
        }
    }

    /// The gap where one chassis ends and the next begins.
    ///
    /// Drawn along the *bottom* of each panel rather than between them, so it
    /// belongs to the unit that owns it and needs no cooperation from
    /// whatever is laying the stack out.
    @ViewBuilder
    private var seam: some View {
        if theme.hardware.panelSeams {
            Rectangle()
                .fill(theme.colors.panelShadow.opacity(0.5))
                .frame(height: max(theme.chrome.borderWidth, 1) * 1.5)
                .allowsHitTesting(false)
        }
    }

    /// Fasteners at the corners, when the theme says its panels are visibly
    /// bolted to something. Inset far enough to clear the panel's own padding
    /// so they land on the face rather than on its edge.
    @ViewBuilder
    private var screws: some View {
        if let style = theme.hardware.screws, theme.chrome.panelStyle == .separated {
            let diameter = theme.metrics.panelPadding * 0.55
            let inset = theme.metrics.panelPadding * 0.35
            // Indexed 0…3 so each corner's seeded rotation is its own and is
            // stable across every redraw.
            ForEach(0..<4, id: \.self) { corner in
                Screw(style: style, index: corner, diameter: diameter)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: [
                            Alignment.topLeading, .topTrailing,
                            .bottomLeading, .bottomTrailing
                        ][corner]
                    )
                    .padding(inset)
            }
        }
    }

    @ViewBuilder
    private var border: some View {
        if theme.chrome.borderWidth > 0 {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .strokeBorder(theme.colors.panelBorder, lineWidth: theme.chrome.borderWidth)
        }
    }

    /// A bevel implying the panel stands proud of, or sits recessed into,
    /// its surround — drawn as a diagonal gradient stroke from
    /// `panelHighlight` toward `panelShadow` (or the reverse, for a recess),
    /// which reads as a catching-the-light edge without a true inner shadow
    /// SwiftUI has no cheap way to draw. `.flat` draws nothing extra, which
    /// is what every theme before this one already looked like.
    @ViewBuilder
    private var relief: some View {
        if theme.chrome.panelRelief != .flat {
            RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                .strokeBorder(reliefGradient, lineWidth: reliefLineWidth)
        }
    }

    private var reliefGradient: LinearGradient {
        let (near, far) = theme.chrome.panelRelief == .raised
            ? (theme.colors.panelHighlight, theme.colors.panelShadow)
            : (theme.colors.panelShadow, theme.colors.panelHighlight)
        return LinearGradient(colors: [near, far], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A hairline against a bright panel already reads; a dark one needs a
    /// touch more width to show at all against its own low contrast.
    private var reliefLineWidth: CGFloat { theme.chrome.isLight ? 1 : 1.5 }

    private var reliefShadowRadius: CGFloat {
        theme.metrics.panelPadding * (theme.chrome.isLight ? 0.15 : 0.25)
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct RackUnit_Previews: PreviewProvider {
    static var previews: some View {
            ThemeGallery {
                RackUnit("Equalizer", status: "10 BAND · ±12 dB") {
                    Text("content")
                }
                .frame(width: 240)
            }
    }
}

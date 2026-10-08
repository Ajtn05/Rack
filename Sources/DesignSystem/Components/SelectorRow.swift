import SwiftUI

/// A row of pushbuttons, mutually exclusive or multi-select.
///
/// The period equivalent is a row of latching pushbuttons: exactly one down
/// for a source selector, any number down for tone switches. Which of the two
/// this is comes from `mode`, and the component makes no other distinction —
/// the caller owns the selection and is told what was pressed.
///
/// **The arrangement is a front panel's, not a web page's.** Each control is
/// three separate things stacked in a column:
///
///     ●        an indicator lamp, on the panel
///   ▭▭▭▭       the cap — blank, and the only part that moves
///   LABEL      the legend, silkscreened on the panel
///
/// Nothing is printed on the cap, because nothing is printed on a real one:
/// a moulded button is a different part from the metal behind it, and the
/// factory screens the panel rather than the part that travels. The lamp is
/// on the panel for the same reason.
///
/// **What "on" looks like.** A latching button does not change colour when
/// pressed — it goes *down*, and the lamp above it lights. This draws both:
/// the cap takes its shading from `chrome.buttonStyle` and reverses it when
/// down, and every button that can latch carries a lamp. Inverting the whole
/// face instead, as this first shipped, had two problems worth naming — it
/// forced every theme to own a `controlActive` dark enough to reverse text
/// on, and at a glance a row of them read as coloured *labels* rather than
/// as switches that were down.
public struct SelectorRow: View {
    @Environment(\.theme) private var theme

    public enum Mode: Sendable {
        /// Exactly one selected. Pressing the selected chip does nothing.
        case exclusive
        /// Any number selected, including none.
        case multiple
        /// Not a latch at all: a button that does something and springs back
        /// — Save, Delete, Flat, Reveal library. Carries no lamp, because
        /// there is no state for one to report, and an unlit lamp that can
        /// never light reads as a switch that is broken.
        case momentary
    }

    /// How much a row asks to be noticed.
    public enum Size: Sendable {
        /// A primary control — the thing a unit's header exists to hold.
        case standard
        /// A secondary choice riding alongside other header content, where a
        /// row of full-sized chips would out-shout the display it is
        /// switching. Same chip, set in the smaller face already used for
        /// captions and legends elsewhere on the panel.
        case compact
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        /// Greyed and unpressable — a source that is not connected.
        public let isEnabled: Bool

        public init(id: String, label: String, isEnabled: Bool = true) {
            self.id = id
            self.label = label
            self.isEnabled = isEnabled
        }
    }

    private let items: [Item]
    private let selection: Set<String>
    private let mode: Mode
    private let size: Size
    private let onSelect: (String) -> Void

    public init(
        items: [Item],
        selection: Set<String>,
        mode: Mode = .exclusive,
        size: Size = .standard,
        onSelect: @escaping (String) -> Void
    ) {
        self.items = items
        self.selection = selection
        self.mode = mode
        self.size = size
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: theme.metrics.tightSpacing) {
            ForEach(items) { item in
                chip(item)
            }
        }
    }

    /// One control: a lamp on the panel, the cap itself, and the legend
    /// silkscreened underneath. Nothing is printed on the cap — that is the
    /// whole arrangement, and it is what a real front panel does. A moulded
    /// button cap is a separate part from the aluminium behind it; the
    /// factory silkscreens the panel, not the part that moves.
    private func chip(_ item: Item) -> some View {
        let isSelected = selection.contains(item.id)

        return Button {
            // An exclusive selector ignores a press on the current selection,
            // because there is nothing for it to mean.
            guard mode != .exclusive || !isSelected else { return }
            onSelect(item.id)
        } label: {
            VStack(spacing: theme.metrics.tightSpacing * 0.45) {
                // The lamp sits above the cap, on the panel — not on the
                // moving part. `.momentary` gets a hole of the same size
                // rather than a lamp, so a row mixing latches and actions
                // still lines its caps and legends up.
                if mode == .momentary {
                    Color.clear
                        .frame(width: lampDiameter, height: lampDiameter)
                } else {
                    lamp(isLit: isSelected)
                }

                cap(label: item.label, isSelected: isSelected)

                legend(item.label)
                    // Physically part of the panel — printed, cut, or raised
                    // into it, per the theme. The lamp reports the state; the
                    // legend just says what the control is, and it does not
                    // change because the switch above it went down.
                    .engraved(theme.engraving)
            }
            // The whole column is the target, including the legend and the
            // gaps — aiming at a cap this small would be unkind.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
    }

    /// The legend, in the face this row is set in.
    ///
    /// A legend does not wrap. Squeezed by a tight row, "Loudness" broke
    /// across two lines mid-word and the control grew a second storey —
    /// which reads as a rendering fault rather than as a control.
    private func legend(_ text: String) -> some View {
        Text(text)
            .font(size == .compact ? theme.typography.caption : theme.typography.label)
            .lineLimit(1)
            .fixedSize()
    }

    /// The moving part: a blank moulded cap, as wide as the legend beneath
    /// it and no taller than a finger needs.
    ///
    /// Sized by an *invisible copy of its own legend* rather than by
    /// `maxWidth: .infinity`. A `Shape` is greedy — given a free width
    /// proposal it takes all of it, which would stretch every cap in a row
    /// to equal width and drag the row itself across the panel. Laying an
    /// unrendered copy of the legend inside the cap makes the cap exactly as
    /// wide as the text under it, and leaves the column hugging its content
    /// the way the rest of the row expects.
    private func cap(label: String, isSelected: Bool) -> some View {
        let isRaised = theme.chrome.buttonStyle == .raised

        return legend(label)
            .opacity(0)
            .padding(.horizontal, theme.metrics.controlSpacing / 2)
            .frame(minWidth: theme.metrics.chipMinWidth, minHeight: capHeight)
            .background(face(isSelected: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)
                    .strokeBorder(
                        theme.colors.panelBorder,
                        lineWidth: max(theme.chrome.borderWidth, 1)
                    )
            )
            // A raised cap stands above the panel until it is pressed, at
            // which point it goes down and takes its shadow with it.
            .shadow(
                color: isRaised && !isSelected ? theme.colors.panelShadow : .clear,
                radius: capShadowRadius,
                x: 0,
                y: isRaised && !isSelected ? capShadowRadius * 0.7 : 0
            )
    }

    /// Reused from the fader's own cap: this is the same idea — the height
    /// of a physical part a finger operates — and a theme that has already
    /// said how tall that is should not be asked twice.
    private var capHeight: CGFloat {
        let base = theme.metrics.faderCapHeight
        return size == .compact ? base * 0.72 : base
    }

    private var capShadowRadius: CGFloat {
        theme.chrome.isLight ? 1 : 1.6
    }

    /// The indicator lamp: a small lens that lights in `controlActive` when
    /// the switch is down and sits dark when it is not.
    ///
    /// On an emissive theme it blooms, using the same `displayGlow` and
    /// radius a readout does — a lit lamp and a lit display are the same
    /// light source on the same front panel and should agree about it.
    private func lamp(isLit: Bool) -> some View {
        let diameter = lampDiameter
        let glows = isLit
            && theme.chrome.displayStyle == .emissive
            && theme.metrics.displayGlowRadius > 0

        return Circle()
            .fill(isLit ? theme.colors.controlActive : theme.colors.controlIdle.opacity(0.3))
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle()
                    .strokeBorder(
                        theme.colors.panelBorder,
                        lineWidth: max(theme.chrome.borderWidth, 1) * 0.7
                    )
            )
            .shadow(
                color: glows ? theme.colors.displayGlow : .clear,
                radius: glows ? theme.metrics.displayGlowRadius * 0.7 : 0
            )
    }

    /// Sized off the legend's own face rather than a fixed number, so a
    /// compact row's lamp shrinks with its text instead of dominating it.
    private var lampDiameter: CGFloat {
        let base = theme.metrics.tightSpacing
        return size == .compact ? base * 0.9 : base * 1.2
    }

    /// The button face.
    ///
    /// `.raised` is a physical latching switch: at rest it catches the light
    /// along its top edge, and pressed it takes the light from below instead
    /// — the standard inset read, and the same two tokens a raised knob and
    /// a raised panel use, so all three read as one material under one light.
    /// `.flat` is the plain fill, for the themes that mean it.
    @ViewBuilder
    private func face(isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.chrome.cornerRadius)

        switch theme.chrome.buttonStyle {
        case .flat:
            // Still says something happened — a flat theme has no relief to
            // spend, so the face itself carries a hint of the accent.
            shape.fill(
                isSelected
                    ? theme.colors.controlActive.opacity(0.18)
                    : theme.colors.buttonFace
            )
        case .raised:
            // The cap's own material, with the relief living entirely in the
            // *rim* — which is what a moulded cap actually does: the face is
            // flat plastic and only its chamfered edges catch anything.
            //
            // Direction comes from `theme.buttonBevel` and the window's light
            // source, and pressing the cap simply inverts the bevel. Washing a
            // highlight-to-shadow gradient across the whole face instead, as
            // this first tried, only works if the theme's `panelHighlight`
            // happens to be lighter than its `buttonFace` — and on
            // `TechnicsTheme` it is not, so every cap came out darker than the
            // panel it sat on. A rim has no such dependency.
            MaterialSurface(theme.buttonMaterial)
                .clipShape(shape)
                .bevelled(shape, isSelected ? theme.buttonBevel.inverted : theme.buttonBevel)
        }
    }
}

/// Rendered under every registered theme, so a new skin shows up here
/// without anyone writing a preview for it.
///
/// `PreviewProvider` rather than the `#Preview` macro: that macro needs a
/// plugin that ships inside Xcode, and this package must build with Command
/// Line Tools alone.
struct SelectorRow_Previews: PreviewProvider {
    static var previews: some View {
            ThemeGallery {
                SelectorRow(
                    items: [
                        SelectorRow.Item(id: "a", label: "Technics"),
                        SelectorRow.Item(id: "b", label: "System"),
                        SelectorRow.Item(id: "c", label: "Braun", isEnabled: false)
                    ],
                    selection: ["a"],
                    onSelect: { _ in }
                )
            }
    }
}

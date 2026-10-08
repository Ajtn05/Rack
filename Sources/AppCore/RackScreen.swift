import DesignSystem
import SwiftUI

/// The rack window: a stack of units assembled from DesignSystem components.
///
/// Everything here says *what* is grouped and *what* a control is bound to.
/// Nothing here says what any of it looks like — no colour, no font, no radius,
/// no spacing value. That is the claim the whole DesignSystem boundary makes,
/// and it is why "make it look like a Braun radio" is one file in `Themes/`.
///
/// The panels themselves live in `RackPanels.swift`, one `View` type each,
/// rather than as computed properties here — see that file's header comment
/// for why: this struct's own `body` only ever reads `engine.theme`, so it
/// stays idle while the amplifier runs and the meters and diagnostics tick
/// thirty times a second in their own panels instead of dragging this one
/// (and everything else on the rack) along with them.
public struct RackScreen: View {
    @Bindable private var engine: EngineController

    /// Which panel a drag currently sits over, for the one-frame highlight
    /// that says where it would land — nothing in `EngineController` needs
    /// to know this mid-drag, so it lives here rather than on the engine.
    @State private var dragTargetedKind: RackPanelKind?

    /// The amplifier's own row of knobs and readouts, measured for real
    /// rather than estimated — see `measurementLayer`. Zero until the first
    /// layout pass reports it, so `minimumWindowWidth` keeps the restated
    /// formula as a floor until this arrives.
    @State private var measuredAmplifierWidth: CGFloat = 0

    /// The analyzer's header — its title, status and mode-selector chips —
    /// measured the same way, and for the same reason: eight mode chips
    /// (`SPECTRUM`, `RESPONSE`, `GONIOMETER`, …) are sized by their own
    /// rendered text, which `tileContentMinimumWidth`'s restated formula
    /// cannot get right any more than it could the amplifier's readouts. Left
    /// out of `minimumWindowWidth`, a window could be resized down to fit the
    /// amplifier alone while the analyzer's header still needed more —
    /// `RackTileLayout` hands a full-width panel its own measured minimum
    /// regardless of what the window actually has, exactly so it clips
    /// nothing, which then overflows past the window's edge instead. See
    /// `analyzerHeaderMeasurementLayer` for why this measures only the
    /// header rather than the whole panel.
    @State private var measuredAnalyzerHeaderWidth: CGFloat = 0

    public init(engine: EngineController) {
        self.engine = engine
    }

    public var body: some View {
        // Cheeks and rack ears flank the scrollable content rather than
        // living inside it, the way a cabinet edge or a mounting flange
        // frames a chassis rather than sitting on the same surface as what is
        // mounted in it. A theme asks for at most one of the two: a unit is
        // either in a wooden case or bolted into a rack, not both.
        HStack(spacing: 0) {
            sideCheek
            rackEar
            rack
            rackEar
            sideCheek
        }
        // Below this, the amplifier's row of controls no longer fits inside
        // its own panel and starts drawing over the padding meant to frame
        // it, rather than being narrower than the window and never getting
        // that far. Measured on the whole window, cheeks included, or a
        // themed pair of them would silently eat into the room the row
        // needs.
        .frame(minWidth: minimumWindowWidth)
        .background(engine.theme.colors.windowBackground)
        // A hidden title bar is still a title bar as far as layout is
        // concerned: the window reserves a safe area for it, and everything
        // here was being laid out *below* that reservation — so the window's
        // own backing showed through above as a pale band, and the side
        // cheeks stopped short of the top edge instead of running the height
        // of the cabinet the way a real one does.
        //
        // The content does not move: `windowTopInset` already pads the first
        // panel down by about the height being reclaimed here, which is what
        // keeps it clear of the traffic lights. What changes is that the
        // cheeks and the window colour now reach the frame's true edges.
        .ignoresSafeArea()
        .theme(engine.theme)
        .background(measurementLayer)
        .background(analyzerHeaderMeasurementLayer)
    }

    /// A second, invisible copy of the amplifier's own content, laid out at
    /// its true ideal width rather than whatever the window happens to be —
    /// the same "ask the real view" approach `RackTileLayout` already uses
    /// for every panel's minimum, extended to the one number that has to be
    /// known *before* the window exists to feed its own `.frame(minWidth:)`.
    ///
    /// `tileContentMinimumWidth`'s restated formula undercounts anything
    /// sized by its own rendered text — which every readout's caption is —
    /// and was exactly the gap that let a window restored at a screen's old,
    /// wider size come back narrower than the amplifier's row of knobs on a
    /// later launch. `.fixedSize()` is what makes the measurement honest: it
    /// tells this copy to report its own natural width regardless of the
    /// zero-sized frame `.background` proposes it, the standard trick for
    /// measuring a view without letting it affect visible layout.
    ///
    /// Scoped to the amplifier's whole panel rather than every full-width
    /// one: the analyzer is the other one, and its *content* — the meters and
    /// the spectrum — redraws at poll rate, so mirroring this for the whole
    /// `AnalyzerPanel` would resubscribe a hidden copy to the same
    /// fast-changing state `RackPanels.swift`'s own header comment describes
    /// splitting panels apart to get away from. See
    /// `analyzerHeaderMeasurementLayer` for the narrower measurement that
    /// avoids that.
    private var measurementLayer: some View {
        AmplifierPanel(engine: engine)
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newValue in
                measuredAmplifierWidth = newValue
            }
    }

    /// The same "ask the real view" measurement, scoped to just the
    /// analyzer's header (`AnalyzerModeSelector`, its title and its status)
    /// rather than the whole panel — the header is what a formula cannot get
    /// right, since its eight mode chips are sized by their own rendered
    /// text, but unlike `AnalyzerPanel`'s `content` it reads no poll-rate
    /// state: `analyzerModeItems` is effectively constant and `analyzerMode`/
    /// `isDisplayIdle` change only on a user action, not thirty times a
    /// second. Wrapped in the real `RackUnit` so the measurement includes its
    /// header chrome, the same way `measuredAmplifierWidth` includes
    /// `AmplifierPanel`'s own; the `content:` closure is a zero-size
    /// placeholder since the header's width does not depend on it.
    private var analyzerHeaderMeasurementLayer: some View {
        RackUnit("Analyzer", status: engine.isDisplayIdle ? "IDLE" : nil) {
            AnalyzerModeSelector(engine: engine)
        } content: {
            Color.clear.frame(width: 0, height: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .hidden()
        .allowsHitTesting(false)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newValue in
            measuredAnalyzerHeaderWidth = newValue
        }
    }

    private var rack: some View {
        ScrollView {
            RackTileLayout(spacing: engine.theme.metrics.panelSpacing) {
                ForEach(engine.panelOrder, id: \.self) { kind in
                    panelView(for: kind)
                        .layoutValue(
                            key: RackTileLayout.IsFullWidthKey.self,
                            value: engine.fullWidthPanels.contains(kind)
                        )
                }
            }
            .padding([.horizontal, .bottom], engine.theme.metrics.panelPadding)
            // Clear of the traffic lights, which float over the content
            // once the title bar is hidden. The larger of the two, not
            // both stacked — `windowTopInset` already accounts for
            // wanting *some* margin up there, and adding the panel's own
            // padding on top of it left a gap distinctly larger than
            // every other edge of the window for no reason anyone was
            // choosing on purpose.
            .padding(.top, max(engine.theme.metrics.windowTopInset, engine.theme.metrics.panelPadding))
        }
    }

    /// One panel, wired up as a drag source (its own title bar, via
    /// `rackUnitDragPayload`), a drop target (its whole body) so it can be
    /// dragged onto any other panel to reorder the rack, a width toggle (via
    /// `rackUnitWidthToggle`) for whether it takes a full row, and a height
    /// toggle (via `rackUnitHeightToggle`) for whether it matches the
    /// tallest panel beside it.
    @ViewBuilder
    private func panelView(for kind: RackPanelKind) -> some View {
        Group {
            switch kind {
            case .amplifier: AmplifierPanel(engine: engine)
            case .saturation: SaturationPanel(engine: engine)
            case .compressor: CompressorPanel(engine: engine)
            case .soundFieldProcessor: SoundFieldProcessorPanel(engine: engine)
            case .limiter: LimiterPanel(engine: engine)
            case .input: InputPanel(engine: engine)
            case .output: OutputPanel(engine: engine)
            case .analyzer: AnalyzerPanel(engine: engine)
            case .equalizer: EqualizerPanel(engine: engine)
            case .applications: ApplicationsPanel(engine: engine)
            case .presets: PresetsPanel(engine: engine)
            case .diagnostics: DiagnosticsPanel(engine: engine)
            case .appearance: AppearancePanel(engine: engine)
            }
        }
        .environment(\.rackUnitDragPayload, kind.rawValue)
        .environment(
            \.rackUnitWidthToggle,
            RackUnitWidthToggle(isFullWidth: engine.fullWidthPanels.contains(kind)) {
                engine.toggleFullWidth(kind)
            }
        )
        .environment(
            \.rackUnitHeightToggle,
            RackUnitHeightToggle(isFullHeight: engine.fullHeightPanels.contains(kind)) {
                engine.toggleFullHeight(kind)
            }
        )
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = RackPanelKind(rawValue: raw) else { return false }
            engine.movePanel(source, before: kind)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dragTargetedKind = kind
            } else if dragTargetedKind == kind {
                dragTargetedKind = nil
            }
        }
        .overlay {
            // The one new mark this adds to the rack, and only while a drag
            // is actually over it — a lit ring in the same colour a pressed
            // switch or an active lamp already uses, not a new colour
            // invented for the occasion.
            if dragTargetedKind == kind {
                RoundedRectangle(cornerRadius: engine.theme.chrome.cornerRadius)
                    .strokeBorder(
                        engine.theme.colors.controlActive,
                        lineWidth: max(engine.theme.chrome.borderWidth, 1) * 2
                    )
                    .allowsHitTesting(false)
            }
        }
        .id(kind)
    }

    /// A wood- or metal-look edge on the window frame, in `accentWarm` —
    /// the cheek's own material, which is not necessarily what the panels
    /// are made of. On `SilverFace` that is walnut against aluminium.
    ///
    /// Solid down its length, with the shading running *across* it rather
    /// than down. That is the way round the physical object works: a cheek
    /// is a length of timber with its edges eased, so the light falls off
    /// toward the two long edges and stays even from top to bottom. Running
    /// the gradient vertically instead — from `panelHighlight` at the top,
    /// through the walnut, to `panelShadow` at the bottom, which is what
    /// this did first — smears a single plank from near-white through brown
    /// to grey over the height of the window, which is not something wood
    /// has ever done.
    @ViewBuilder
    private var sideCheek: some View {
        if let cheek = engine.theme.hardware.sideCheeks {
            // The cheek's own material — walnut, brushed metal, whatever the
            // theme says the cabinet edge is made of. Previously assembled
            // here from `accentWarm` plus a gradient, which meant the screen
            // was deciding what a piece of furniture looked like; now it just
            // draws whatever material the theme handed it.
            MaterialSurface(cheek.material)
                .overlay(
                    // The long edges of a length of timber ease away from the
                    // light. Runs *across* the cheek, not down it: a plank is
                    // even along its length.
                    LinearGradient(
                        colors: [
                            engine.theme.colors.panelShadow.opacity(0.5),
                            .clear,
                            engine.theme.colors.panelShadow.opacity(0.3)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(engine.theme.colors.panelBorder)
                        .frame(width: max(engine.theme.chrome.borderWidth, 1))
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(engine.theme.colors.panelBorder)
                        .frame(width: max(engine.theme.chrome.borderWidth, 1))
                }
                .frame(width: sideCheekWidth)
        }
    }

    private var sideCheekWidth: CGFloat { engine.theme.metrics.panelPadding * 2.5 }

    /// A 19-inch mounting flange, when the theme says its units are bolted
    /// into a rack. The same width as a cheek so the window's proportions do
    /// not change depending on which kind of furniture a theme chose.
    @ViewBuilder
    private var rackEar: some View {
        if engine.theme.hardware.rackEars {
            RackEar(width: sideCheekWidth)
        }
    }

    /// The narrowest the window can go before *some* panel — whichever one
    /// turns out to have the widest row of controls that are not allowed to
    /// flex the way a slider or a chip list can — stops fitting inside its
    /// own padding and starts overlapping it instead of being framed by it.
    /// That is the point at which the padding is doing nothing, so the
    /// window should stop there.
    ///
    /// `RackTileLayout` gives every panel a full row to itself once the
    /// window is this narrow — nothing else it could tile beside would fit
    /// either — so the same number that bounds the window has to come from
    /// this rack's own fixed geometry rather than from `RackTileLayout`'s own
    /// measurement: a window has to declare a minimum size before SwiftUI has
    /// laid anything out inside it to measure, which is the one place this
    /// still has to restate a panel's floor as a formula rather than ask the
    /// view itself. What this leaves out — anything sized by its own text, a
    /// preset's name, a device's name — is *not* caught once the window
    /// exists: a solo full-width panel narrower than its own measured
    /// minimum still gets that minimum from `RackTileLayout`, wider than the
    /// window rather than clipped, precisely so nothing silently clips —
    /// which means this floor overflowing its own formula's blind spot reads
    /// as content spilling past the window's edge, not as a graceful
    /// fallback. `measuredAmplifierWidth` and `measuredAnalyzerHeaderWidth`
    /// exist to close that gap for the two panels whose own text is wide
    /// enough to matter; the formula only has to be right about the rows
    /// built from pure geometry, which are the ones it can actually get
    /// right.
    private var minimumWindowWidth: CGFloat {
        // Real measurements, where they have reported, beat the formula —
        // both already include their own panel's chrome (`RackUnit`'s
        // padding and bevel), unlike the formula, which is why each is
        // compared directly against the fully assembled floor rather than
        // folded into `tileContentMinimumWidth` below.
        let formulaFloor = RackPanelKind.allCases
            .map(tileContentMinimumWidth(for:))
            .max() ?? 0
        let restatedWidth = formulaFloor + engine.theme.metrics.panelPadding * 4 + cheekAllowance
        let measuredWidth = max(measuredAmplifierWidth, measuredAnalyzerHeaderWidth)
        guard measuredWidth > 0 else { return restatedWidth }
        return max(measuredWidth + cheekAllowance, restatedWidth)
    }

    /// The width a cheek or a rack ear takes on each of the window's two
    /// edges, doubled. A theme asks for at most one of the two, so at most
    /// one term here is ever non-zero.
    private var cheekAllowance: CGFloat {
        let hasCheeks = engine.theme.hardware.sideCheeks != nil
        let hasRackEars = engine.theme.hardware.rackEars
        guard hasCheeks || hasRackEars else { return 0 }
        return sideCheekWidth * 2
    }

    /// The narrowest a panel's own content can go before something inside it
    /// — a row of knobs, a fixed-width field, a name column — no longer
    /// fits. Restated here from each component's own geometry rather than
    /// measured, the same way the amplifier's rows always were: nothing
    /// below is allowed to flex, so it is what the panel actually needs
    /// rather than what it happens to have been given.
    ///
    /// Feeds only `minimumWindowWidth` now — `RackTileLayout` measures every
    /// panel's real minimum width directly and does not consult this. What
    /// is here deliberately leaves out anything sized by its own text — a
    /// chip's legend, a device name, a preset name — the same restraint the
    /// original amplifier calculation always used for its own toggle row.
    /// Getting that pixel-exact would mean measuring rendered text, which is
    /// exactly what a static formula cannot do and `RackTileLayout` exists to
    /// do instead; what is here is every row whose width is pure geometry.
    private func tileContentMinimumWidth(for kind: RackPanelKind) -> CGFloat {
        let metrics = engine.theme.metrics
        // The same widened gutter the amplifier and compressor grids use
        // between their columns.
        let wideGutter = metrics.controlSpacing * 1.6

        switch kind {
        case .amplifier:
            // RotaryControl's large/standard scale factors aren't exposed
            // outside DesignSystem, so its two sizes here are restated as
            // the diameters they produce.
            let volumeKnob = metrics.knobDiameter * 1.45
            // Balance, preamp, the two tone shelves and boost are all
            // standard-size knobs sharing one centre line.
            let standardKnobCount: CGFloat = 5
            let knobRow = volumeKnob + metrics.knobDiameter * standardKnobCount
                + wideGutter * standardKnobCount
            // The readouts under those knobs: six columns, each a
            // fixed-width value plus its unit suffix, sharing the grid's
            // gutters with the knobs above them.
            let readoutRow = (metrics.readoutMinWidth + metrics.controlSpacing) * 6
                + wideGutter * standardKnobCount
            return max(knobRow, readoutRow)

        case .saturation:
            // Drive and Mix: two standard knobs on one line, the same grid
            // shape as the compressor's own, just narrower.
            let knobRow = metrics.knobDiameter * 2 + wideGutter
            let readoutRow = (metrics.readoutMinWidth + metrics.controlSpacing) * 2 + wideGutter
            return max(knobRow, readoutRow)

        case .compressor:
            // Threshold, ratio, attack, release, makeup: five standard knobs
            // on one line, the same grid shape as the amplifier's own.
            let knobRow = metrics.knobDiameter * 5 + wideGutter * 4
            let readoutRow = (metrics.readoutMinWidth + metrics.controlSpacing) * 5 + wideGutter * 4
            return max(knobRow, readoutRow)

        case .limiter:
            // Ceiling and Release: two standard knobs on one line, the same
            // grid shape as Saturation's own.
            let knobRow = metrics.knobDiameter * 2 + wideGutter
            let readoutRow = (metrics.readoutMinWidth + metrics.controlSpacing) * 2 + wideGutter
            return max(knobRow, readoutRow)

        case .soundFieldProcessor:
            // Two rows built from pure geometry rather than a preset name:
            // one mix knob and its two readouts (reverb or delay), and the
            // widest row, width and crossfeed each with their own knob and
            // readout side by side.
            let mixRow = metrics.knobDiameter + wideGutter * 2 + metrics.readoutMinWidth * 2
            let widthCrossfeedRow = metrics.knobDiameter * 2 + wideGutter * 3 + metrics.readoutMinWidth * 2
            return max(mixRow, widthCrossfeedRow)

        case .equalizer:
            // Ten fixed-width fader caps and the gaps between them —
            // restated from `FaderBank`, which computes a cap as half the
            // knob diameter.
            let faderCapWidth = metrics.knobDiameter / 2
            return faderCapWidth * 10 + metrics.controlSpacing * 9

        case .applications:
            // One channel strip's fixed parts: an icon, a name column, an
            // activity lamp, a slider given just enough room to be dragged
            // rather than merely toggled, and a mute chip.
            let lampDiameter = metrics.tightSpacing * 2
            let sliderMinimum = metrics.knobDiameter
            return metrics.iconSize + metrics.controlSpacing
                + metrics.appNameWidth + metrics.controlSpacing
                + lampDiameter + metrics.controlSpacing
                + sliderMinimum + metrics.controlSpacing
                + metrics.chipMinWidth

        case .presets:
            // The name field and its Save chip — the one row always on
            // screen, whatever else the library holds.
            return RackLayoutConstants.presetNameFieldWidth + metrics.tightSpacing + metrics.chipMinWidth

        case .diagnostics:
            // Three readout columns per row, both rows the same shape.
            return metrics.readoutMinWidth * 3 + metrics.controlSpacing * 2

        case .output:
            // A single device chip — the row wraps to nothing narrower than
            // one, however many devices there are.
            return metrics.chipMinWidth

        case .input:
            // A device chip like Output's, but the level knob and its readout
            // sit beside each other underneath, and that pair is the wider of
            // the two rows.
            return metrics.knobDiameter
                + metrics.controlSpacing * 1.6
                + metrics.readoutMinWidth

        case .analyzer:
            // The meter strip's own width — restated from `LevelMeter` and
            // `PhaseMeter`, both of which take whatever they are given, so
            // this is the floor the theme itself names for one rather than a
            // measurement of either.
            return metrics.meterWidth

        case .appearance:
            // One theme swatch — restated from `ThemePicker`, whose grid
            // already reflows on its own and never asks for less than this.
            return metrics.appNameWidth * 0.78
        }
    }
}

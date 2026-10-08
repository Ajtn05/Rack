import AudioCore
import DesignSystem
import SwiftUI

/// The analyzer's own header accessory — the mode-selector chips — as a
/// standalone type so `RackScreen` can measure its real rendered width
/// without instantiating the rest of the panel, which reads the poll-rate
/// meters this file's own header comment already documents avoiding a
/// second subscription to.
struct AnalyzerModeSelector: View {
    let engine: EngineController

    var body: some View {
        SelectorRow(
            items: engine.analyzerModeItems,
            selection: [engine.analyzerMode.rawValue],
            mode: .exclusive,
            size: .compact
        ) { engine.selectAnalyzerMode(id: $0) }
    }
}

struct AnalyzerPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Analyzer", status: status) {
            AnalyzerModeSelector(engine: engine)
        } content: {
            VStack(spacing: engine.theme.metrics.controlSpacing) {
                VFDPlate {
                    VStack(spacing: engine.theme.metrics.tightSpacing) {
                        display
                        Rectangle()
                            .fill(engine.theme.colors.panelBorder)
                            .frame(height: 1)
                        HStack(spacing: engine.theme.metrics.controlSpacing) {
                            LevelMeter(
                                channels: [
                                    LevelMeter.Channel(
                                        label: "L",
                                        position: engine.meterLeft.position,
                                        hold: engine.meterLeft.holdPosition
                                    ),
                                    LevelMeter.Channel(
                                        label: "R",
                                        position: engine.meterRight.position,
                                        hold: engine.meterRight.holdPosition
                                    )
                                ],
                                isDimmed: isMonitorDimmed
                            )
                            .frame(maxWidth: .infinity)
                            .help("Left/right peak level, in dB.")

                            LabelledReadout(
                                "Peak", Readout(engine.peakDisplay, unit: "dB", characterCount: 6)
                            )
                        }

                        HStack(spacing: engine.theme.metrics.controlSpacing) {
                            PhaseMeter(
                                position: engine.correlation.position,
                                isDimmed: isMonitorDimmed
                            )
                            .frame(maxWidth: .infinity)
                            .help(
                                "Stereo phase correlation. +1 is fully in phase, "
                                    + "−1 is fully out of phase and will cancel in mono."
                            )

                            LabelledReadout(
                                "Phase", Readout(engine.correlationDisplay, characterCount: 6)
                            )
                        }
                    }
                    // While idle the plate's monitoring is switched off at the
                    // source — the poll loop stops and the analyzer's capture
                    // leaves the IOProc (see `EngineController.enterDisplayIdle`).
                    // The live content is kept in the layout but hidden, with a
                    // standby placeholder drawn over it, so nothing reflows when the
                    // display sleeps and nothing is left frozen mid-swing behind it.
                    .opacity(engine.isDisplayIdle ? 0 : 1)
                    .overlay {
                        if engine.isDisplayIdle { placeholder("STANDBY") }
                    }
                }

                // Send the plate to standby by hand, without waiting out the idle
                // timeout — and, once asleep, wake it again. Lit while the display
                // is in standby; disabled when the engine is off, since there is
                // nothing to put to sleep.
                SelectorRow(
                    items: [
                        SelectorRow.Item(
                            id: "standby", label: "Standby",
                            isEnabled: engine.status.isRunning
                        )
                    ],
                    selection: engine.isDisplayIdle ? ["standby"] : [],
                    mode: .multiple,
                    size: .compact
                ) { _ in engine.toggleDisplayIdle() }
            }
        }
    }

    /// Whether the plate is drawn in its idle colour — either because there
    /// is nothing driving it (the engine is off, or the equalizer is
    /// bypassed) or because nobody has touched a control for a while. Both
    /// are the same picture: a display that is telling the truth but is not
    /// being watched.
    private var isMonitorDimmed: Bool {
        engine.isAnalyzerDimmed || engine.isDisplayIdle
    }

    private var status: String? {
        engine.isDisplayIdle ? "IDLE" : nil
    }

    /// Where "0 VU" sits on the needle's sweep — everything from there up
    /// prints in the warning colour, which is what a real VU meter's red zone
    /// above 0 is.
    private var vuWarningThreshold: Double {
        VUMeter.position(forDecibels: VUMeter.referenceDecibels)
    }

    /// What the plate's main area is showing, above the meter and peak strip.
    /// Every branch here draws on the `VFDPlate` its caller already
    /// provided — nothing below draws a plate, a border, or a background of
    /// its own.
    @ViewBuilder
    private var display: some View {
        switch engine.analyzerMode {
        case .spectrum:
            if engine.spectrumBands.isEmpty {
                // Nothing has been published yet — the engine is off, or it
                // has only just started. A blank box reads as a fault; a line
                // of text reads as a state.
                placeholder(engine.status.isRunning ? "LISTENING…" : "NO SIGNAL")
            } else {
                SpectrumBars(
                    bands: engine.spectrumBands,
                    isDimmed: isMonitorDimmed,
                    drawsPlate: false
                )
                .help("Real-time frequency spectrum.")
            }
        case .vu:
            HStack(spacing: engine.theme.metrics.controlSpacing) {
                NeedleMeter(
                    position: engine.vuLeft.position,
                    warningThreshold: vuWarningThreshold,
                    caption: "L",
                    isDimmed: isMonitorDimmed
                )
                .frame(maxWidth: .infinity)
                .help("Average (VU) level, left channel.")
                NeedleMeter(
                    position: engine.vuRight.position,
                    warningThreshold: vuWarningThreshold,
                    caption: "R",
                    isDimmed: isMonitorDimmed
                )
                .frame(maxWidth: .infinity)
                .help("Average (VU) level, right channel.")
            }
        case .pulse:
            NeedleMeter(
                position: engine.beatPulsePosition,
                warningThreshold: 0.7,
                marks: [
                    NeedleMeter.Mark(position: 0, label: "0"),
                    NeedleMeter.Mark(position: 0.5, label: nil, isMajor: false),
                    NeedleMeter.Mark(position: 1, label: "HIT")
                ],
                caption: "PULSE",
                isDimmed: isMonitorDimmed
            )
            .frame(maxWidth: .infinity)
            .help("Beat pulse. Snaps on a detected bass onset and decays back down.")
        case .response:
            // The same component the amplifier draws, on the same axis, so the
            // two describe the same thing in the same shape.
            ResponseCurve(
                points: engine.responseCurve,
                range: engine.responseRange,
                gridlines: engine.responseGridlines,
                rules: engine.responseRules,
                isDimmed: isMonitorDimmed,
                isOverlay: true
            )
            .help("The equalizer's combined frequency response.")
        case .overlay:
            if engine.spectrumBands.isEmpty {
                placeholder(engine.status.isRunning ? "LISTENING…" : "NO SIGNAL")
            } else {
                // The bars carry the dB scale; the curve draws only its
                // trace on top of them, in overlay style. Their vertical
                // scales genuinely differ — the bars are absolute level, the
                // curve is relative gain — so this is a shape traced over a
                // picture, not a second axis. What it answers is "is the
                // boost landing where the music has anything to boost",
                // which needs exactly that much and no more.
                ZStack {
                    SpectrumBars(
                        bands: engine.spectrumBands,
                        isDimmed: isMonitorDimmed,
                        drawsPlate: false
                    )
                    ResponseCurve(
                        points: engine.responseCurve,
                        range: engine.responseRange,
                        isDimmed: isMonitorDimmed,
                        isOverlay: true
                    )
                }
                .help("The frequency spectrum, with the equalizer's response traced over it.")
            }
        case .goniometer:
            if engine.goniometerPoints.isEmpty {
                placeholder(engine.status.isRunning ? "LISTENING…" : "NO SIGNAL")
            } else {
                Goniometer(points: engine.goniometerPoints, isDimmed: isMonitorDimmed)
                    .help("Stereo image shape. A vertical line is mono; a wide circle is wide stereo.")
            }
        case .oscilloscope:
            if engine.oscilloscopePoints.isEmpty {
                placeholder(engine.status.isRunning ? "LISTENING…" : "NO SIGNAL")
            } else {
                ResponseCurve(
                    points: engine.oscilloscopePoints,
                    range: -1...1,
                    isDimmed: isMonitorDimmed
                )
                .help("The waveform over the last window of audio.")
            }
        case .off:
            // Nothing drawn and nothing computed.
            placeholder("ANALYZER OFF")
        }
    }

    /// A dim line where a display would be, at the height one would occupy —
    /// so switching modes never shuffles the panels below.
    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(engine.theme.typography.caption)
            .foregroundStyle(engine.theme.colors.labelSecondary)
            .frame(
                maxWidth: .infinity,
                minHeight: engine.theme.metrics.graphHeight,
                alignment: .center
            )
    }
}

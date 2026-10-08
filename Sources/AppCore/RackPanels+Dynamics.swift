import AudioCore
import DesignSystem
import SwiftUI

struct SaturationPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Saturation") {
            SelectorRow(
                items: [SelectorRow.Item(id: "saturation", label: "Saturation")],
                selection: engine.isSaturationEnabled ? ["saturation"] : [],
                mode: .multiple
            ) { _ in engine.isSaturationEnabled.toggle() }
        } content: {
            KnobBank(engine: engine, controls: [
                ParameterControl(
                    label: "Drive", keyPath: \.saturationDriveDecibels,
                    range: Saturation.driveRangeDecibels, format: .decibels,
                    unit: "dB", characterCount: 4,
                    help: "Drive into the saturator — more drive means more harmonic warmth."
                ),
                ParameterControl(
                    label: "Mix", keyPath: \.saturationMixAmount,
                    range: Saturation.mixRange, format: .percent,
                    unit: "%", characterCount: 3,
                    help: "How much of the saturated signal is blended back with the dry signal."
                ),
            ])
        }
    }
}

/// The chain's brickwall ceiling, on its own rack unit rather than folded
/// into the amplifier — the same reasoning that gives Saturation and the
/// Compressor their own units: each is a distinct stage with its own knobs,
/// and stacking all of them into the amplifier's own panel is what made that
/// panel the widest, most crowded thing on the rack. Defaults to *on*, unlike
/// its neighbours — see `DSPParameters.isLimiterEnabled`.
struct LimiterPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Limiter") {
            SelectorRow(
                items: [SelectorRow.Item(id: "limiter", label: "Limiter")],
                selection: engine.isLimiterEnabled ? ["limiter"] : [],
                mode: .multiple
            ) { _ in engine.isLimiterEnabled.toggle() }
            .help(
                "Holds the output at the ceiling so nothing downstream of the "
                    + "equalizer can clip. On by default."
            )
        } content: {
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                KnobBank(engine: engine, controls: [
                    ParameterControl(
                        label: "Ceiling", keyPath: \.limiterCeilingDecibels,
                        range: Limiter.ceilingRangeDecibels, format: .decibels,
                        unit: "dB", characterCount: 5,
                        help: "The output never leaves above this level, in dBFS."
                    ),
                    ParameterControl(
                        label: "Release", keyPath: \.limiterReleaseMilliseconds,
                        range: Limiter.releaseRangeMilliseconds, format: .milliseconds,
                        unit: "ms", characterCount: 4,
                        help: "How quickly the limiter lets go once the signal drops back under the ceiling."
                    ),
                ])

                // Lit only while it is actually catching something, outside
                // the knob grid rather than a third column in it — a plain
                // reading, not a control, the same relationship the
                // amplifier's own Cut readout has to Auto Headroom. A limiter
                // that never lights is one staying out of the way; one lit
                // constantly says something upstream is too hot.
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    LabelledReadout(
                        "Reduction",
                        Readout(
                            engine.isLimiting ? engine.limiterReductionDisplay : "—",
                            unit: "dB",
                            characterCount: 5
                        )
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct CompressorPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Compressor", status: status) {
            SelectorRow(
                items: [SelectorRow.Item(id: "compressor", label: "Compressor")],
                selection: engine.isCompressorEnabled ? ["compressor"] : [],
                mode: .multiple
            ) { _ in engine.isCompressorEnabled.toggle() }
        } content: {
            VStack(alignment: .leading, spacing: engine.theme.metrics.controlSpacing) {
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    NeedleMeter(
                        position: engine.compressorGainReductionPosition,
                        // Never triggers — real gain-reduction meters have no
                        // red zone, they are a plain deflection reading.
                        warningThreshold: 1.01,
                        marks: NeedleMeter.gainReductionMarks,
                        caption: "GR",
                        isDimmed: engine.isAnalyzerDimmed
                    )
                    .frame(maxWidth: .infinity)
                    .help("Gain reduction — how much the compressor is turning the signal down right now.")

                    LabelledReadout(
                        "Reduction",
                        Readout(engine.compressorGainReductionDisplay, unit: "dB", characterCount: 5)
                    )
                }

                KnobBank(engine: engine, controls: [
                    ParameterControl(
                        label: "Threshold", keyPath: \.compressorThresholdDecibels,
                        range: Compressor.thresholdRangeDecibels, format: .decibels,
                        unit: "dB", characterCount: 5,
                        help: "Level above which compression starts, in dB."
                    ),
                    ParameterControl(
                        label: "Ratio", keyPath: \.compressorRatio,
                        range: Compressor.ratioRange, format: .ratio,
                        unit: nil, characterCount: 6,
                        help: "How much the signal above the threshold is turned down."
                    ),
                    ParameterControl(
                        label: "Attack", keyPath: \.compressorAttackMilliseconds,
                        range: Compressor.attackRangeMilliseconds, format: .milliseconds,
                        unit: "ms", characterCount: 4,
                        help: "How quickly compression engages once the signal crosses the threshold."
                    ),
                    ParameterControl(
                        label: "Release", keyPath: \.compressorReleaseMilliseconds,
                        range: Compressor.releaseRangeMilliseconds, format: .milliseconds,
                        unit: "ms", characterCount: 4,
                        help: "How quickly compression lets go once the signal drops back below the threshold."
                    ),
                    ParameterControl(
                        label: "Makeup", keyPath: \.compressorMakeupDecibels,
                        range: Compressor.makeupRangeDecibels, format: .signedDecibels,
                        unit: "dB", characterCount: 5,
                        help: "Gain added back after compression, in dB."
                    ),
                ])
            }
        }
    }

    private var status: String? {
        engine.status.isRunning ? nil : engine.status.displayName
    }
}

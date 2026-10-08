import AudioCore
import DesignSystem
import SwiftUI

struct SoundFieldProcessorPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Sound Field Processor") {
            SelectorRow(
                items: [
                    SelectorRow.Item(id: "reverb", label: "Reverb"),
                    SelectorRow.Item(id: "delay", label: "Delay"),
                    SelectorRow.Item(id: "crossfeed", label: "Crossfeed")
                ],
                selection: enabledEffectIDs,
                mode: .multiple
            ) { id in
                switch id {
                case "reverb": engine.isReverbEnabled.toggle()
                case "delay": engine.isDelayEnabled.toggle()
                case "crossfeed": engine.isCrossfeedEnabled.toggle()
                default: break
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: engine.theme.metrics.controlSpacing) {
                VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                    SelectorRow(
                        items: engine.reverbPresetItems,
                        selection: [engine.reverbPreset.rawValue],
                        mode: .exclusive
                    ) { engine.selectReverbPreset(id: $0) }

                    effectRow(
                        value: engine.reverbWetAmount,
                        onChange: { engine.reverbWetAmount = $0 },
                        mixDisplay: engine.reverbWetDisplay,
                        mixHelp: "How much reverb is blended in with the dry signal.",
                        secondLabel: "Latency",
                        secondDisplay: engine.reverbLatencyDisplay
                    )
                }

                divider

                VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                    SelectorRow(
                        items: engine.delayPresetItems,
                        selection: [engine.delayPreset.rawValue],
                        mode: .exclusive
                    ) { engine.selectDelayPreset(id: $0) }

                    effectRow(
                        value: engine.delayWetAmount,
                        onChange: { engine.delayWetAmount = $0 },
                        mixDisplay: engine.delayWetDisplay,
                        mixHelp: "How much delay is blended in with the dry signal.",
                        secondLabel: "Time",
                        secondDisplay: engine.delayTimeDisplay
                    )
                }

                divider

                HStack(spacing: engine.theme.metrics.controlSpacing * 1.6) {
                    RotaryControl(
                        label: "Width", value: engine.stereoWidth, range: 0...2,
                        detentAtCentre: true,
                        size: .standard, variant: .secondary, labelPlacement: .none
                    ) { engine.stereoWidth = $0 }
                    .help("Stereo width. Narrower than 100% narrows the image; wider spreads it.")
                    LabelledReadout(
                        "Width", Readout(engine.stereoWidthDisplay, unit: "%", characterCount: 3)
                    )
                    RotaryControl(
                        label: "Crossfeed", value: engine.crossfeedAmount,
                        range: Crossfeed.amountRange,
                        size: .standard, variant: .secondary, labelPlacement: .none
                    ) { engine.crossfeedAmount = $0 }
                    .help("Headphone crossfeed. Blends a treble-rolled-off copy of each channel into the other, softening hard-panned recordings on headphones.")
                    LabelledReadout(
                        "Crossfeed", Readout(engine.crossfeedAmountDisplay, unit: "%", characterCount: 3)
                    )
                }
            }
        }
    }

    /// One effect's mix knob, its own percentage readout, and a second
    /// readout beside it — latency for reverb, time for delay.
    private func effectRow(
        value: Double,
        onChange: @escaping (Double) -> Void,
        mixDisplay: String,
        mixHelp: String,
        secondLabel: String,
        secondDisplay: String
    ) -> some View {
        HStack(spacing: engine.theme.metrics.controlSpacing * 1.6) {
            RotaryControl(
                label: "Mix", value: value, range: 0...1,
                size: .standard, variant: .secondary, labelPlacement: .none,
                onChange: onChange
            )
            .help(mixHelp)
            LabelledReadout("Mix", Readout(mixDisplay, unit: "%", characterCount: 3))
            LabelledReadout(secondLabel, Readout(secondDisplay, unit: "ms", characterCount: 3))
        }
    }

    private var enabledEffectIDs: Set<String> {
        var ids: Set<String> = []
        if engine.isReverbEnabled { ids.insert("reverb") }
        if engine.isDelayEnabled { ids.insert("delay") }
        if engine.isCrossfeedEnabled { ids.insert("crossfeed") }
        return ids
    }

    private var divider: some View {
        Rectangle()
            .fill(engine.theme.colors.panelBorder)
            .frame(height: 1)
    }
}

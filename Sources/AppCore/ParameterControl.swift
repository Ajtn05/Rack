import AudioCore
import DesignSystem
import SwiftUI

/// One knob-plus-readout pair, described rather than hand-written.
///
/// `CompressorPanel`, `SaturationPanel` and `LimiterPanel` used to write each
/// row of `RotaryControl`s and its matching row of `LabelledReadout`s
/// separately, with the label typed once for each — ten strings for five
/// controls, kept in sync by hand. A `[ParameterControl]` array plus
/// `KnobBank` emits both rows from the same source, so the label can only be
/// written once.
///
/// Deliberately not reached for everywhere a knob appears: `AmplifierPanel`'s
/// mixed knob sizes, `AnalyzerPanel`'s mode switch and
/// `SoundFieldProcessorPanel`'s preset rows are genuinely bespoke, and a
/// table that grew a case for each of them would be worse than what it
/// replaced. This is for the uniform "row of N knobs over row of N readouts"
/// clusters only.
struct ParameterControl: Identifiable {
    let label: String
    let keyPath: WritableKeyPath<DSPParameters, Double>
    let range: ClosedRange<Double>
    let format: ReadoutFormat
    let unit: String?
    let characterCount: Int
    let help: String
    var detentAtCentre = false

    var id: String { label }
}

/// A row of knobs over a row of matching readouts, both built from the same
/// `[ParameterControl]` — see `ParameterControl`'s own doc comment for why
/// this exists and where it does not belong.
struct KnobBank: View {
    let engine: EngineController
    let controls: [ParameterControl]
    var size: RotaryControl.Size = .standard

    var body: some View {
        Grid(
            horizontalSpacing: engine.theme.metrics.controlSpacing * 1.6,
            verticalSpacing: engine.theme.metrics.tightSpacing
        ) {
            GridRow {
                ForEach(controls) { control in
                    RotaryControl(
                        label: control.label,
                        value: engine[dynamicMember: control.keyPath],
                        range: control.range,
                        detentAtCentre: control.detentAtCentre,
                        size: size, variant: .secondary, labelPlacement: .none
                    ) { engine[dynamicMember: control.keyPath] = $0 }
                    .help(control.help)
                }
            }
            GridRow {
                ForEach(controls) { control in
                    LabelledReadout(
                        control.label,
                        Readout(
                            engine[dynamicMember: control.keyPath], format: control.format,
                            unit: control.unit, characterCount: control.characterCount
                        )
                    )
                }
            }
        }
    }
}

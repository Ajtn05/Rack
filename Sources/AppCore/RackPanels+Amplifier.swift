import AudioCore
import DesignSystem
import SwiftUI

struct AmplifierPanel: View {
    let engine: EngineController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        RackUnit("Amplifier", status: status) {
            // One power control, in one place. "On" and "Bypass" sitting in
            // different corners with different styling read as two switches
            // for the same idea. Power runs the engine; whether the EQ is in
            // circuit is a question about the equalizer, and now lives there.
            HStack(spacing: engine.theme.metrics.controlSpacing) {
                SelectorRow(
                    items: [SelectorRow.Item(id: "power", label: "Power")],
                    selection: engine.status.isRunning ? ["power"] : [],
                    mode: .multiple
                ) { _ in engine.toggle() }

                SelectorRow(
                    items: [SelectorRow.Item(id: "settings", label: "Settings")],
                    selection: [],
                    mode: .momentary
                ) { _ in openSettings() }
            }
        } content: {
            // Two rows of controls in a primary Grid — volume, balance,
            // preamp, tone and boost, each with its own readout — and a
            // secondary row of effect toggles below it. The primary row is
            // physically the biggest cluster of controls on the panel; the
            // secondary row is where a switch like `TONE DEFEAT` belongs,
            // once there are enough of them that a single row would crowd.
            //
            // A Grid rather than an HStack of VStacks so both rows of the
            // primary cluster are genuinely rows. Stacking each control with
            // its own readout looked right and was not: a large knob and a
            // small one make two columns of different heights, and whatever
            // alignment the row is given then applies to the *stacks*, not to
            // the things inside them. A grid aligns row by row instead —
            // every knob on one centre line, every readout on one baseline,
            // whatever their diameters.
            //
            // The legend lives on the readout rather than under the knob, so
            // each column is named exactly once.
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                Grid(
                    // Wider than the panel's ordinary control spacing. Six
                    // controls with room to breathe reads as a row of
                    // instruments; at the tighter default spacing they crowded
                    // together like a list.
                    horizontalSpacing: engine.theme.metrics.controlSpacing * 1.6,
                    verticalSpacing: engine.theme.metrics.tightSpacing
                ) {
                    GridRow {
                        // Volume is physically the biggest control on real
                        // equipment, which is how you find it without looking.
                        RotaryControl(
                            label: "Volume", value: engine.volume, range: 0...1,
                            size: .large, labelPlacement: .none
                        ) { engine.volume = $0 }
                        .help("Overall output level.")

                        // Standard size rather than small: at small they read as
                        // an afterthought next to a large Volume knob. Still
                        // visibly secondary to Volume, but no longer the
                        // smallest thing in the row.
                        RotaryControl(
                            label: "Balance", value: engine.balance, range: -1...1,
                            detentAtCentre: true, size: .standard, labelPlacement: .none
                        ) { engine.balance = $0 }
                        .help("Left/right balance. Centre is even.")

                        RotaryControl(
                            label: "Preamp", value: engine.preampDecibels,
                            range: engine.gainRange, detentAtCentre: true,
                            size: .standard, labelPlacement: .none
                        ) { engine.preampDecibels = $0 }
                        .help("Gain applied before the tone controls, in dB.")

                        // Bass and treble shelves, separate from the graphic
                        // EQ. Most people reach for these two before the
                        // ten-band fader bank.
                        RotaryControl(
                            label: "Bass", value: engine.toneBassDecibels,
                            range: (-DSPParameters.toneMaximumDecibels...DSPParameters.toneMaximumDecibels), detentAtCentre: true,
                            size: .standard, variant: .secondary, labelPlacement: .none
                        ) { engine.toneBassDecibels = $0 }
                        .help("Low-shelf tone control, in dB.")

                        RotaryControl(
                            label: "Treble", value: engine.toneTrebleDecibels,
                            range: (-DSPParameters.toneMaximumDecibels...DSPParameters.toneMaximumDecibels), detentAtCentre: true,
                            size: .standard, variant: .secondary, labelPlacement: .none
                        ) { engine.toneTrebleDecibels = $0 }
                        .help("High-shelf tone control, in dB.")

                        // BOOST replaces Loudness: a depth control rather than
                        // a switch, because nothing about the contour was ever
                        // binary — it was a switch pretending a continuous
                        // amount was one of two states.
                        RotaryControl(
                            label: "Boost", value: engine.boostDepthDecibels,
                            range: (0...DSPParameters.boostMaximumDepthDecibels),
                            size: .standard, variant: .secondary, labelPlacement: .none
                        ) { engine.boostDepthDecibels = $0 }
                        .help("Loudness-style bass and treble contour depth.")
                    }

                    GridRow {
                        // Named for the control, not for a measurement. It was
                        // labelled LEVEL, which reads as output level and is not:
                        // it is where the volume control is set. On screen beside a
                        // PEAK of −9.7 it claimed an output of −0.0, and a level
                        // cannot exceed its own peak.
                        LabelledReadout(
                            "Volume", Readout(engine.volumeDisplay, unit: "dB", characterCount: 5)
                        )
                        LabelledReadout(
                            "Balance", Readout(engine.balanceDisplay, characterCount: 5)
                        )
                        LabelledReadout(
                            "Preamp", Readout(engine.preampDisplay, unit: "dB", characterCount: 5)
                        )
                        LabelledReadout(
                            "Bass", Readout(engine.toneBassDisplay, unit: "dB", characterCount: 5)
                        )
                        LabelledReadout(
                            "Treble", Readout(engine.toneTrebleDisplay, unit: "dB", characterCount: 5)
                        )
                        LabelledReadout(
                            "Boost", Readout(engine.boostDepthDisplay, unit: "dB", characterCount: 5)
                        )
                    }
                }

                // The secondary row: effect toggles, rather than controls with
                // their own readout. `TONE DEFEAT` bypasses the shelves above
                // without moving them; `Auto Headroom` is what keeps raising
                // Boost from ever raising the peak level, and the readout
                // beside it says by how much — so the behaviour is never a
                // mystery, and never invisible when it is doing nothing.
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    SelectorRow(
                        items: [SelectorRow.Item(id: "toneDefeat", label: "Tone Defeat")],
                        selection: engine.isToneDefeated ? ["toneDefeat"] : [],
                        mode: .multiple
                    ) { _ in engine.isToneDefeated.toggle() }

                    SelectorRow(
                        items: [SelectorRow.Item(id: "headroom", label: "Auto Headroom")],
                        selection: engine.isHeadroomCompensationEnabled ? ["headroom"] : [],
                        mode: .multiple
                    ) { _ in engine.isHeadroomCompensationEnabled.toggle() }

                    LabelledReadout(
                        "Cut", Readout(engine.headroomCompensationDisplay, unit: "dB", characterCount: 4)
                    )

                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Nothing while it is running.
    ///
    /// It used to name the device and the rate, which the Output panel already
    /// shows as a selected chip and Diagnostics already shows as a number — the
    /// same fact in three places, and the only one of the three that could not
    /// be acted on.
    private var status: String? {
        engine.status.isRunning ? nil : engine.status.displayName
    }
}

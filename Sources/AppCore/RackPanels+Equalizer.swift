import AudioCore
import DesignSystem
import SwiftUI

struct EqualizerPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Equalizer", status: "10 BAND · ±12 dB") {
            // Two rows, not one, because these are two different kinds of
            // control: EQ is a latching switch that stays down, Flat is an
            // action that happens once and springs back. Sharing a row meant
            // sharing a mode, and the lamp EQ needs would then have appeared
            // on Flat as well — permanently dark, on a button that can never
            // light it.
            HStack(spacing: engine.theme.metrics.tightSpacing) {
                SelectorRow(
                    items: [SelectorRow.Item(id: "eq", label: "EQ")],
                    // The EQ lamp lights when the equalizer is in circuit,
                    // which is the inverse of bypass. Hi-fi equalizers have
                    // exactly this switch and call it defeat or tone-in.
                    selection: engine.isBypassed ? [] : ["eq"],
                    mode: .multiple
                ) { _ in engine.isBypassed.toggle() }

                SelectorRow(
                    items: [
                        SelectorRow.Item(id: "flat", label: "Flat", isEnabled: !engine.isFlat)
                    ],
                    selection: [],
                    mode: .momentary
                ) { _ in engine.resetParameters() }
            }
        } content: {
            // Ten fixed-width fader caps and nothing else — the panel's
            // natural width, not the window's. That is what lets it tile
            // beside Applications instead of claiming a full row on its own.
            FaderBank(
                bands: engine.bands.map { band in
                    FaderBank.Band(
                        id: band.id,
                        label: band.label,
                        value: engine.bandGain(forBand: band.id),
                        isShelf: band.isShelf
                    )
                },
                range: engine.gainRange
            ) { band, value in
                engine.setBandGain(value, forBand: band)
            }
            .help("Ten-band graphic equaliser — each fader boosts or cuts its own frequency band, up to ±12 dB.")
        }
    }
}

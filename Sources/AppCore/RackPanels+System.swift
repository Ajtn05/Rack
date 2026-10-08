import AudioCore
import DesignSystem
import SwiftUI

struct DiagnosticsPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Diagnostics", status: engine.status.displayName) {
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    labelled("Rate", Readout(sampleRateValue, unit: "Hz", characterCount: 6))
                    labelled("Buffer", Readout("\(engine.readout.averageBufferFrames)", characterCount: 4))
                    // Named for what it is. It was labelled "Start", which
                    // reads as latency and is not — round-trip IO latency is
                    // the number worth showing and is not wired up yet.
                    labelled("Rebuild", Readout(startMilliseconds, unit: "ms", characterCount: 4))
                }
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    labelled("Silent", Readout("\(engine.readout.silentBuffers)", characterCount: 4))
                    labelled("Mismatch", Readout("\(engine.readout.mismatchedBuffers)", characterCount: 4))
                    labelled(
                        "Faults",
                        Readout(
                            "\(engine.readout.dspFaults)", characterCount: 4,
                            isEmphasised: engine.readout.dspFaults > 0
                        )
                    )
                }
                // `Buffer` above is an *average* (frames ÷ callbacks) and reads
                // zero for two very different reasons — the IOProc never ran, or
                // it ran and received nothing. `IOProcs` separates them: a
                // climbing count with a zero average is the second case.
                //
                // The raw frame total sat beside this while the mic monitor's
                // cold-start behaviour was being chased, and has been taken out
                // now that it is not: it answered nothing `IOProcs` and `Buffer`
                // do not already answer between them, and an eight-digit number
                // that changes every poll is the most restless thing on a panel
                // otherwise made of settled ones. `framesRendered` is still
                // carried in `EngineReadout` — `averageBufferFrames` is computed
                // from it — it is simply no longer shown on its own.
                HStack(spacing: engine.theme.metrics.controlSpacing) {
                    labelled("IOProcs", Readout("\(engine.readout.buffersRendered)", characterCount: 8))
                }
                if let detail = engine.errorDetail {
                    Text(detail)
                        .font(engine.theme.typography.caption)
                        .foregroundStyle(engine.theme.colors.labelSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func labelled(_ title: String, _ readout: Readout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(engine.theme.typography.caption)
                .foregroundStyle(engine.theme.colors.labelSecondary)
            readout
        }
    }

    private var sampleRateValue: String {
        engine.readout.sampleRate > 0 ? "\(Int(engine.readout.sampleRate))" : "—"
    }

    private var startMilliseconds: String {
        engine.readout.lastStartMilliseconds > 0
            ? "\(Int(engine.readout.lastStartMilliseconds))"
            : "—"
    }
}

struct AppearancePanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Appearance") {
            // Two rows, not one. The theme picker is an exclusive selector —
            // exactly one of those chips is down at a time — and Idle Dimming
            // is an independent switch that happens to live in the same
            // panel. Sat on the end of the same row they read as one control:
            // a seventh theme, next to six real ones, that could apparently
            // be selected alongside Champagne. Separating the rows is what
            // says they answer different questions.
            VStack(alignment: .leading, spacing: engine.theme.metrics.controlSpacing) {
                // Swatches rather than a chip row. Every chip was drawn in
                // the *current* theme, so a dozen skins differed by nothing
                // but their names and picking one meant applying it to find
                // out what it was.
                ThemePicker(selection: engine.themeID) { engine.themeID = $0 }

                // Whether the monitor is allowed to go to standby on its own is
                // a question about how the display behaves, which is what this
                // panel already answers for the rest of the skin.
                SelectorRow(
                    items: [SelectorRow.Item(id: "idle", label: "Idle Dimming")],
                    selection: engine.isIdleTimeoutEnabled ? ["idle"] : [],
                    mode: .multiple
                ) { _ in engine.isIdleTimeoutEnabled.toggle() }
            }
        }
    }
}

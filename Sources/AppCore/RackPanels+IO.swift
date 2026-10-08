import AudioCore
import DesignSystem
import SwiftUI

struct InputPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Input", status: status) {
            HStack(spacing: engine.theme.metrics.tightSpacing) {
                SelectorRow(
                    items: [SelectorRow.Item(id: "monitor", label: "Monitor")],
                    selection: engine.isMicMonitorEnabled ? ["monitor"] : [],
                    mode: .multiple
                ) { _ in engine.isMicMonitorEnabled.toggle() }

                // Mute stays operable while the monitor is off, rather than
                // being disabled along with it: it is the control someone
                // reaches for in a hurry, and one that refuses to arm until
                // some other switch is set is one you cannot trust to be
                // already set when you need it.
                SelectorRow(
                    items: [SelectorRow.Item(id: "mute", label: "Mute")],
                    selection: engine.isMicMonitorMuted ? ["mute"] : [],
                    mode: .multiple
                ) { _ in engine.isMicMonitorMuted.toggle() }

                // Defeatable, and labelled as a guard rather than as an
                // effect — the same reasoning the limiter's own switch
                // follows. Someone with monitors across the room at a sensible
                // level has a real reason to overrule this, and an app that
                // refuses outright is one they would work around by turning
                // the whole monitor off.
                SelectorRow(
                    items: [SelectorRow.Item(id: "guard", label: "Guard")],
                    selection: engine.isFeedbackGuardEnabled ? ["guard"] : [],
                    mode: .multiple
                ) { _ in engine.isFeedbackGuardEnabled.toggle() }
            }
        } content: {
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                SelectorRow(
                    items: engine.inputDevices.map {
                        SelectorRow.Item(id: $0.uid, label: $0.name)
                    },
                    selection: engine.micMonitorSelection,
                    mode: .exclusive
                ) { engine.selectMicMonitorDevice(uid: $0) }

                HStack(spacing: engine.theme.metrics.controlSpacing * 1.6) {
                    RotaryControl(
                        label: "Level", value: engine.micMonitorVolume, range: 0...1,
                        size: .standard, variant: .secondary, labelPlacement: .none
                    ) { engine.micMonitorVolume = $0 }
                    .help("How loud the microphone is mixed into the output.")

                    LabelledReadout(
                        "Level", Readout(engine.micMonitorVolumeDisplay, unit: "%", characterCount: 3)
                    )
                }

                // What the panel says depends on what is actually happening,
                // because "use headphones" is advice and the other two are
                // reports. A line that never changes is one that stops being
                // read, and the case where the monitor is on and deliberately
                // silent is exactly the one that needs explaining.
                Text(advice)
                    .font(engine.theme.typography.caption)
                    .foregroundStyle(engine.theme.colors.labelSecondary)
            }
        }
    }

    private var status: String? {
        if engine.inputDevices.isEmpty { return "NO INPUTS" }
        if engine.isMicMonitorDeviceMissing { return "DEVICE GONE" }
        if !engine.isMicMonitorEnabled { return "OFF" }
        if engine.isMicMonitorMuted { return "MUTED" }
        // Ahead of the hold: a howl in progress is the more urgent fact, and
        // the two cannot both be true anyway — a held monitor has no
        // microphone in the path to duck.
        if engine.isDuckingFeedback { return "DUCKING" }
        if engine.isMicHeldForFeedback { return "HELD" }
        return nil
    }

    private var advice: String {
        if engine.isMicHeldForFeedback {
            return """
                Held: the output is a speaker, so monitoring would feed back. \
                Plug in headphones, or switch Guard off to override.
                """
        }
        if engine.isDuckingFeedback {
            return "Feedback detected — microphone cut by \(engine.feedbackDuckDisplay) dB."
        }
        return "Use headphones — monitoring through speakers can feed back."
    }
}

struct OutputPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Output", status: status) {
            SelectorRow(
                items: engine.outputDevices.map {
                    SelectorRow.Item(id: $0.uid, label: $0.name)
                },
                selection: engine.readout.outputDeviceUID.map { [$0] } ?? [],
                mode: .exclusive
            ) { engine.selectOutputDevice(uid: $0) }
        }
    }

    private var status: String? {
        guard !engine.outputDevices.isEmpty else { return "NO DEVICES" }
        return engine.status.isRunning ? nil : engine.status.displayName
    }
}

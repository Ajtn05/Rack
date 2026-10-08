import AudioCore
import DesignSystem
import SwiftUI

struct ApplicationsPanel: View {
    let engine: EngineController

    var body: some View {
        RackUnit("Applications", status: status) {
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                if engine.appRows.isEmpty {
                    Text(placeholder)
                        .font(engine.theme.typography.caption)
                        .foregroundStyle(engine.theme.colors.labelSecondary)
                } else {
                    ForEach(engine.appRows) { row in
                        applicationRow(row)
                    }
                }
            }
        }
    }

    /// One channel strip: what it is, whether it is making a sound, how loud,
    /// and whether it is muted.
    private func applicationRow(_ row: AppMixRow) -> some View {
        HStack(spacing: engine.theme.metrics.controlSpacing) {
            // The icon is what makes a list of applications scannable. Resolved
            // from the running process rather than guessed from the bundle ID.
            Group {
                if let icon = AppIdentity.icon(forProcessID: row.processID) {
                    icon.resizable().interpolation(.high)
                } else {
                    // Not every audio process is a windowed app with an icon.
                    // A blank of the same size keeps the names in one column.
                    Color.clear
                }
            }
            .frame(
                width: engine.theme.metrics.iconSize,
                height: engine.theme.metrics.iconSize
            )

            Text(row.displayName)
                .font(engine.theme.typography.label)
                .foregroundStyle(
                    row.isPlaying
                        ? engine.theme.colors.labelPrimary
                        : engine.theme.colors.labelSecondary
                )
                .lineLimit(1)
                .frame(
                    width: engine.theme.metrics.appNameWidth, alignment: .leading
                )

            // Playing, as opposed to merely open. A process object exists for
            // anything that has ever made a sound.
            ActivityLamp(isOn: row.isPlaying)

            LevelSlider(
                value: row.volume,
                // A fader on a stream we cannot address individually would be
                // a lie, so it is shown disabled rather than hidden.
                isEnabled: !row.isGlobalOnly
            ) { engine.setVolume($0, forApp: row) }
                .frame(maxWidth: .infinity)
                .help("This application's own volume.")

            if row.isGlobalOnly {
                Text("GLOBAL")
                    .font(engine.theme.typography.caption)
                    .foregroundStyle(engine.theme.colors.labelSecondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                SelectorRow(
                    items: [SelectorRow.Item(id: "mute", label: "Mute")],
                    selection: row.isMuted ? ["mute"] : [],
                    mode: .multiple
                ) { _ in engine.setMuted(!row.isMuted, forApp: row) }
            }
        }
    }

    private var status: String? {
        guard engine.status.isRunning else { return engine.status.displayName }
        return engine.appRows.isEmpty ? "NOTHING PLAYING" : nil
    }

    /// A line of explanation where the list would be. An empty box is the one
    /// state that reads as a fault whatever caused it.
    private var placeholder: String {
        engine.status.isRunning
            ? "Nothing is playing. Applications appear here when they make a sound."
            : "Switch the amplifier on to see what is playing."
    }
}

struct PresetsPanel: View {
    let engine: EngineController

    /// Lives here now, not on `RackScreen` — this is the one piece of state
    /// only this panel's own row touches, so it has no reason to be
    /// declared anywhere its dependency set is shared with a panel that
    /// redraws thirty times a second.
    @State private var newPresetName = ""

    var body: some View {
        RackUnit("Presets", status: engine.hasUnsavedChanges ? "MODIFIED" : nil) {
            VStack(alignment: .leading, spacing: engine.theme.metrics.tightSpacing) {
                if !engine.presets.isEmpty {
                    // Labelled, because clicking a chip already recalled the
                    // preset and nothing on screen said so.
                    Text("RECALL")
                        .font(engine.theme.typography.caption)
                        .foregroundStyle(engine.theme.colors.labelSecondary)
                    SelectorRow(
                        // "None" first: the explicit way back to no preset at
                        // all, so that leaving one behind is a click rather
                        // than something that only ever happens by touching a
                        // slider.
                        items: [SelectorRow.Item(id: "none", label: "None")]
                            + engine.presets.map {
                                SelectorRow.Item(id: $0.id.uuidString, label: $0.name)
                            },
                        selection: engine.activePresetID.map { [$0.uuidString] } ?? ["none"],
                        mode: .exclusive
                    ) { id in
                        if id == "none" {
                            engine.clearActivePreset()
                        } else if let uuid = UUID(uuidString: id) {
                            engine.applyPreset(id: uuid)
                        }
                    }
                }

                // Naming and saving a new preset is its own row. It used to
                // share one with Update / Rule for device / Delete, and at
                // this panel's width — half the window, since Applications
                // sits beside it — the combined row ran past the panel edge
                // and the window clipped whatever didn't fit, which is what
                // cut "Rule for device" off mid-word.
                HStack(spacing: engine.theme.metrics.tightSpacing) {
                    TextField("Name", text: $newPresetName)
                        .textFieldStyle(.plain)
                        .font(engine.theme.typography.label)
                        .foregroundStyle(engine.theme.colors.labelPrimary)
                        .padding(.horizontal, engine.theme.metrics.tightSpacing)
                        .padding(.vertical, engine.theme.metrics.tightSpacing / 2)
                        .background(
                            RoundedRectangle(cornerRadius: engine.theme.chrome.cornerRadius)
                                .fill(engine.theme.colors.controlTrack)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: engine.theme.chrome.cornerRadius)
                                .strokeBorder(
                                    engine.theme.colors.panelBorder,
                                    lineWidth: max(engine.theme.chrome.borderWidth, 1)
                                )
                        )
                        .frame(width: RackLayoutConstants.presetNameFieldWidth)
                        .onSubmit(savePreset)

                    SelectorRow(
                        items: [
                            SelectorRow.Item(
                                id: "save", label: "Save",
                                isEnabled: !newPresetName.trimmingCharacters(in: .whitespaces)
                                    .isEmpty
                            )
                        ],
                        selection: [],
                        mode: .momentary
                    ) { _ in savePreset() }
                    Spacer(minLength: 0)
                }

                // What to do with the preset already loaded — its own row,
                // and only present when there is one.
                if engine.activePresetID != nil {
                    SelectorRow(
                        items: activePresetActionItems,
                        selection: [],
                        mode: .momentary,
                        onSelect: handleActivePresetAction
                    )
                }

                if !engine.rules.isEmpty {
                    Text("\(engine.rules.count) auto-switch rule(s) · first match wins")
                        .font(engine.theme.typography.caption)
                        .foregroundStyle(engine.theme.colors.labelSecondary)
                }
            }
        }
    }

    private var activePresetActionItems: [SelectorRow.Item] {
        [
            SelectorRow.Item(id: "update", label: "Update"),
            SelectorRow.Item(
                id: "rule", label: "Rule for device",
                isEnabled: engine.readout.outputDeviceUID != nil
            ),
            SelectorRow.Item(id: "delete", label: "Delete")
        ]
    }

    private func handleActivePresetAction(_ id: String) {
        guard let active = engine.activePresetID else { return }
        switch id {
        case "update": engine.updatePreset(id: active)
        case "rule": engine.addRuleForCurrentDevice(presetID: active)
        case "delete": engine.deletePreset(id: active)
        default: break
        }
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        engine.savePreset(named: name)
        newPresetName = ""
    }
}

import AppCore
import AudioCore
import Foundation

/// Presets, the rule engine, and the store's behaviour when a file is not what
/// it should be.
func runPresetTests() {
    Check.suite("RuleCondition — matching") {
        let context = RuleContext(
            outputDeviceUID: "AppleUSB:Chu2",
            outputDeviceName: "Chu2 DSP",
            foregroundAppBundleID: "com.apple.Safari"
        )

        Check.isTrue(
            RuleCondition.outputDevice(uid: "AppleUSB:Chu2").matches(context),
            "an exact device UID matches"
        )
        Check.isTrue(
            !RuleCondition.outputDevice(uid: "other").matches(context),
            "a different UID does not"
        )

        // Bluetooth UIDs are opaque and change with pairing, so name matching
        // exists as the humane alternative.
        Check.isTrue(
            RuleCondition.outputDeviceNameContains("chu2").matches(context),
            "device name matching ignores case"
        )
        Check.isTrue(
            !RuleCondition.outputDeviceNameContains("AirPods").matches(context),
            "and does not match a different device"
        )
        Check.isTrue(
            !RuleCondition.outputDeviceNameContains("").matches(context),
            "an empty fragment matches nothing rather than everything"
        )

        Check.isTrue(
            RuleCondition.foregroundApp(bundleID: "com.apple.Safari").matches(context),
            "the frontmost app matches"
        )
        Check.isTrue(RuleCondition.always.matches(context), "always matches")
        Check.isTrue(
            RuleCondition.always.matches(RuleContext()),
            "always matches even an empty context"
        )
        Check.isTrue(
            !RuleCondition.outputDevice(uid: "x").matches(RuleContext()),
            "nothing else matches an empty context"
        )
    }

    Check.suite("RuleEngine — top down, first match wins") {
        let quiet = Preset(name: "Quiet", parameters: .flat)
        let loud = Preset(name: "Loud", parameters: .flat)
        let presets = [quiet, loud]

        let context = RuleContext(
            outputDeviceUID: "speakers",
            outputDeviceName: "Speakers",
            foregroundAppBundleID: "com.apple.Music"
        )

        // Both rules match. List order decides, and nothing else — no
        // specificity scoring, because a user has to be able to predict the
        // outcome by reading the list.
        let rules = [
            AutoSwitchRule(condition: .always, presetID: quiet.id),
            AutoSwitchRule(condition: .outputDevice(uid: "speakers"), presetID: loud.id)
        ]
        Check.equal(
            RuleEngine.matchingPreset(in: rules, for: context, knownPresets: presets),
            quiet.id,
            "the earlier rule wins"
        )

        Check.equal(
            RuleEngine.matchingPreset(
                in: rules.reversed(), for: context, knownPresets: presets
            ),
            loud.id,
            "reordering changes the outcome, and that is the whole mechanism"
        )

        // A disabled rule is skipped, not treated as non-matching-and-stop.
        let disabled = [
            AutoSwitchRule(condition: .always, presetID: quiet.id, isEnabled: false),
            AutoSwitchRule(condition: .always, presetID: loud.id)
        ]
        Check.equal(
            RuleEngine.matchingPreset(in: disabled, for: context, knownPresets: presets),
            loud.id,
            "a disabled rule is passed over"
        )

        // A rule pointing at a deleted preset must not stop evaluation. The
        // user meant to switch to something; the next rule beats nothing.
        let dangling = [
            AutoSwitchRule(condition: .always, presetID: UUID()),
            AutoSwitchRule(condition: .always, presetID: loud.id)
        ]
        Check.equal(
            RuleEngine.matchingPreset(in: dangling, for: context, knownPresets: presets),
            loud.id,
            "a rule naming a deleted preset is skipped, not fatal"
        )

        Check.isTrue(
            RuleEngine.matchingPreset(in: [], for: context, knownPresets: presets) == nil,
            "no rules means no switch"
        )
        Check.isTrue(
            RuleEngine.matchingPreset(
                in: [AutoSwitchRule(condition: .outputDevice(uid: "nope"), presetID: quiet.id)],
                for: context, knownPresets: presets
            ) == nil,
            "no match means no switch"
        )
    }

    Check.suite("PresetStore — round trip") {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)

        Check.isTrue(store.loadPresets().isEmpty, "an absent library reads as empty")

        var parameters = DSPParameters.flat
        parameters.bandGains[0] = 6
        parameters.preampDecibels = -3
        parameters.boostDepthDecibels = 6
        parameters.toneBassDecibels = 3
        parameters.toneTrebleDecibels = -2
        parameters.isToneDefeated = true
        parameters.isHeadroomCompensationEnabled = false
        parameters.reverbPreset = .church
        parameters.reverbWetAmount = 0.3
        parameters.isReverbEnabled = true
        let preset = Preset(name: "Late night", parameters: parameters)

        store.save(presets: [preset])
        let loaded = store.loadPresets()
        Check.equal(loaded.count, 1, "the preset survives a round trip")
        Check.equal(loaded.first?.name, "Late night", "with its name")
        Check.isTrue(
            loaded.first?.parameters == parameters,
            "and every parameter, exactly"
        )

        let rule = AutoSwitchRule(condition: .outputDevice(uid: "abc"), presetID: preset.id)
        store.save(rules: [rule])
        Check.equal(store.loadRules().count, 1, "rules round trip too")
        Check.equal(
            store.loadRules().first?.condition, .outputDevice(uid: "abc"),
            "with their condition intact"
        )
    }

    Check.suite("PresetStore — files are meant to be read and edited") {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)

        store.save(presets: [Preset(name: "Readable", parameters: .flat)])
        let text = (try? String(
            contentsOf: directory.appending(path: "presets.json"), encoding: .utf8
        )) ?? ""

        // The brief says people will want to edit and share these, which makes
        // formatting a feature rather than a nicety.
        Check.isTrue(text.contains("\n"), "output is pretty-printed, not one line")
        Check.isTrue(text.contains("\"name\""), "keys are readable")
        Check.isTrue(
            text.range(of: "bandGains") != nil, "and the parameters are all there"
        )
    }

    Check.suite("PresetStore — a broken file is preserved, not eaten") {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)

        store.save(presets: [Preset(name: "Precious", parameters: .flat)])

        // Someone hand-edits their presets and drops a comma. Losing the file
        // as a punishment for a typo is not acceptable.
        let url = directory.appending(path: "presets.json")
        try? "{ this is not json".write(to: url, atomically: true, encoding: .utf8)

        Check.isTrue(store.loadPresets().isEmpty, "the app starts empty rather than crashing")

        let survivors = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        Check.isTrue(
            survivors.contains { $0.lastPathComponent.contains("invalid-") },
            "the unreadable file is moved aside where the user can recover it"
        )
        Check.isTrue(
            !FileManager.default.fileExists(atPath: url.path),
            "and out of the way, so the next save starts clean"
        )
    }

    Check.suite("PresetStore — session state") {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)

        var mix = AppMix()
        mix.upsert(
            AppMix.Entry(
                bundleID: "com.apple.Safari", processID: 1,
                displayName: "Safari", volume: 0.4
            )
        )
        var parameters = DSPParameters.flat
        parameters.balance = -0.25
        let id = UUID()

        store.save(
            state: PresetStore.SessionState(
                activePresetID: id, appMix: mix, parameters: parameters
            )
        )
        let state = store.loadState()

        Check.equal(state.activePresetID, id, "the active preset is remembered")
        Check.close(state.parameters.balance, -0.25, tolerance: 0.0001, "as are the settings")
        Check.equal(state.appMix.entries.count, 1, "and the per-application mix")
        Check.close(
            state.appMix.entries[0].volume, 0.4, tolerance: 0.0001,
            "with its level"
        )
    }
}

import AudioCore
import Foundation

/// Preset management and auto-switching, layered onto `EngineController`.
extension EngineController {
    // MARK: - Applying

    /// Load a preset's settings into the engine.
    public func apply(_ preset: Preset) {
        activePresetID = preset.id
        update { $0 = preset.parameters }
        scheduleStateSave()
    }

    public func applyPreset(id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        apply(preset)
    }

    /// Mark nothing as active, without touching a single parameter.
    ///
    /// The explicit "no preset" choice — the equivalent of an init/default
    /// slot in a plugin's preset menu. Distinct from simply never having
    /// loaded one: this is for stepping *out* of a preset deliberately, to
    /// stop the "modified" badge comparing your settings against one you no
    /// longer mean to be editing.
    public func clearActivePreset() {
        guard activePresetID != nil else { return }
        activePresetID = nil
        scheduleStateSave()
    }

    /// The preset currently loaded, if the settings still match it.
    ///
    /// Touching a slider after loading a preset leaves you with something that
    /// is no longer that preset, and saying otherwise would be a small lie the
    /// user notices the moment they switch away and back.
    public var activePreset: Preset? {
        guard let activePresetID,
              let preset = presets.first(where: { $0.id == activePresetID })
        else { return nil }
        return preset.parameters == parameters ? preset : nil
    }

    /// True when the settings have drifted from the loaded preset.
    public var hasUnsavedChanges: Bool {
        guard let activePresetID,
              let preset = presets.first(where: { $0.id == activePresetID })
        else { return false }
        return preset.parameters != parameters
    }

    // MARK: - Editing

    @discardableResult
    public func savePreset(named name: String) -> Preset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset(
            name: trimmed.isEmpty ? "Untitled" : trimmed,
            parameters: parameters
        )
        presets.append(preset)
        activePresetID = preset.id
        store.save(presets: presets)
        scheduleStateSave()
        return preset
    }

    /// Overwrite a preset with the current settings.
    public func updatePreset(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].parameters = parameters
        activePresetID = id
        store.save(presets: presets)
        scheduleStateSave()
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        // Rules pointing at a deleted preset are removed too. Leaving them
        // would make the list read as though something would happen when
        // nothing will.
        let removed = rules.count
        rules.removeAll { $0.presetID == id }
        if activePresetID == id { activePresetID = nil }

        store.save(presets: presets)
        if rules.count != removed { store.save(rules: rules) }
        scheduleStateSave()
    }

    // MARK: - Rules

    public func addRule(_ rule: AutoSwitchRule) {
        rules.append(rule)
        store.save(rules: rules)
    }

    public func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        store.save(rules: rules)
    }

    public func setRuleEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
        store.save(rules: rules)
    }

    public func moveRule(from source: Int, to destination: Int) {
        guard rules.indices.contains(source),
              destination >= 0, destination <= rules.count
        else { return }
        let rule = rules.remove(at: source)
        rules.insert(rule, at: min(destination, rules.count))
        store.save(rules: rules)
    }

    /// The obvious one-click rule: "when I am on this device, use this preset."
    ///
    /// Offered because it is what almost every rule will be, and because
    /// composing one by hand means knowing a device UID, which nobody does.
    public func addRuleForCurrentDevice(presetID: UUID) {
        guard let uid = readout.outputDeviceUID, !uid.isEmpty else { return }
        addRule(AutoSwitchRule(condition: .outputDevice(uid: uid), presetID: presetID))
    }

    /// What the rules are currently looking at.
    public var ruleContext: RuleContext {
        RuleContext(
            outputDeviceUID: readout.outputDeviceUID,
            outputDeviceName: readout.deviceName,
            foregroundAppBundleID: foregroundAppBundleID
        )
    }

    /// Evaluate the rules and switch if one matches something new.
    ///
    /// Called when the output device changes and when the frontmost
    /// application changes. Re-applying the preset that is already active is
    /// skipped, or every app switch would stamp on settings the user had just
    /// adjusted by hand.
    func evaluateAutoSwitch() {
        guard !rules.isEmpty else { return }
        guard
            let matchID = RuleEngine.matchingPreset(
                in: rules, for: ruleContext, knownPresets: presets
            )
        else { return }
        guard matchID != activePresetID else { return }
        applyPreset(id: matchID)
    }
}

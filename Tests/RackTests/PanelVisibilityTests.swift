import AppCore
import AudioCore
import Foundation

@MainActor
func runPanelVisibilityTests() {
    func withStore(_ body: (PresetStore) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rack-panel-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        body(PresetStore(directory: directory))
    }

    Check.suite("Panel visibility — new and legacy sessions show the four defaults") {
        withStore { store in
            // Power stays off so these model tests never start audio capture.
            store.save(state: PresetStore.SessionState(isPoweredOn: false))
            let engine = EngineController(store: store)
            Check.equal(
                engine.visiblePanelOrder,
                [.amplifier, .analyzer, .equalizer, .soundFieldProcessor],
                "a session without a visibility preference uses the requested defaults"
            )
            Check.equal(store.loadState().enabledPanels, nil, "legacy state has no visibility field")
        }
    }

    Check.suite("Panel visibility — the amplifier is required even in incomplete saves") {
        withStore { store in
            for saved in [[], ["unknown-panel"], ["analyzer", "analyzer", "unknown-panel"]] {
                store.save(state: PresetStore.SessionState(enabledPanels: saved, isPoweredOn: false))
                let engine = EngineController(store: store)
                engine.setPanelEnabled(.amplifier, isEnabled: false)
                Check.isTrue(engine.enabledPanels.contains(.amplifier), "the amplifier cannot be disabled")
                let expected: [RackPanelKind] = saved.contains("analyzer")
                    ? [.amplifier, .analyzer] : [.amplifier]
                Check.equal(engine.visiblePanelOrder, expected, "unknown names and duplicates are ignored")
            }
        }
    }

    Check.suite("Panel visibility — hiding retains sound, order, and size preferences") {
        withStore { store in
            var parameters = DSPParameters.flat
            parameters.bandGains[0] = 6
            parameters.isSaturationEnabled = true
            let order: [RackPanelKind] = [.equalizer, .amplifier, .soundFieldProcessor, .analyzer]
            store.save(state: PresetStore.SessionState(
                parameters: parameters,
                panelOrder: order.map(\.rawValue),
                fullWidthPanels: ["equalizer"],
                fullHeightPanels: ["equalizer"],
                isPoweredOn: false
            ))
            let engine = EngineController(store: store)
            let originalOrder = engine.panelOrder
            engine.setPanelEnabled(.equalizer, isEnabled: false)
            Check.equal(engine.visiblePanelOrder, [.amplifier, .soundFieldProcessor, .analyzer], "a hidden panel leaves the layout")
            Check.equal(engine.parameters, parameters, "visibility does not change audio processing")
            Check.equal(engine.panelOrder, originalOrder, "hiding preserves rack order")
            Check.equal(engine.fullWidthPanels, [.equalizer], "hiding preserves width")
            Check.equal(engine.fullHeightPanels, [.equalizer], "hiding preserves height")
            engine.setPanelEnabled(.equalizer, isEnabled: true)
            Check.equal(engine.visiblePanelOrder, order, "reenabling returns the panel to its position")

            for kind in RackPanelKind.allCases where kind != .amplifier {
                engine.setPanelEnabled(kind, isEnabled: false)
            }
            Check.equal(engine.visiblePanelOrder, [.amplifier], "every optional component can be hidden")
            engine.setPanelEnabled(.diagnostics, isEnabled: true)
            Check.equal(engine.visiblePanelOrder, [.amplifier, .diagnostics], "an optional component can be added")
            engine.resetPanelVisibility()
            Check.equal(engine.enabledPanels, RackPanelKind.defaultEnabledPanels, "reset restores the four defaults")
            Check.equal(engine.panelOrder, originalOrder, "reset also preserves rack order")
        }
    }

    Check.suite("Panel visibility — a customized selection survives persistence") {
        withStore { store in
            let enabled: Set<RackPanelKind> = [.amplifier, .compressor, .output, .appearance]
            store.save(state: PresetStore.SessionState(
                enabledPanels: enabled.map(\.rawValue), isPoweredOn: false
            ))
            Check.equal(Set(store.loadState().enabledPanels ?? []), Set(enabled.map(\.rawValue)), "the store round-trips visibility")
            let engine = EngineController(store: store)
            Check.equal(engine.enabledPanels, enabled, "launch restores the saved selection")
            Check.equal(engine.visiblePanelOrder, [.amplifier, .compressor, .output, .appearance], "launch omits unselected defaults")
        }
    }
}

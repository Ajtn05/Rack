import SwiftUI

/// What drops down from the menu bar item.
///
/// A native menu — plain `Button`s, `Toggle`s and `Divider`s — rather than a
/// themed panel, and deliberately so. The rack's skin is a claim about what
/// *Rack* looks like; a menu belongs to the menu bar, and a walnut-and-chrome
/// dropdown next to the system's own menus would be the one place the skin
/// stopped being a pleasure and started being a costume. It is also why this
/// file names no colour, font or metric: there is nothing here to style.
///
/// The set of items is "what is worth doing without opening the window":
/// power, bypass, standby, and the way back to the window itself. Everything
/// that needs a knob stays on the front panel.
public struct MenuBarScreen: View {
    private let engine: EngineController

    public init(engine: EngineController) {
        self.engine = engine
    }

    public var body: some View {
        // The one line of status: what the engine is doing and what it is
        // playing through. Disabled because it is a readout, not a control —
        // the same thing the front panel's own status line says.
        Text(statusLine)

        Divider()

        Button(engine.status.isRunning ? "Stop Engine" : "Start Engine") {
            engine.toggle()
        }
        .keyboardShortcut("p", modifiers: [.option, .command])

        Toggle("Bypass", isOn: bypassBinding)
            .keyboardShortcut("b", modifiers: [.option, .command])

        Toggle("Standby", isOn: standbyBinding)
            .disabled(!engine.status.isRunning)

        Divider()

        Button("Open Rack Window") {
            engine.showWindow?()
        }
        .keyboardShortcut("r", modifiers: [.option, .command])

        Divider()

        Toggle("Open at Login", isOn: loginBinding)
        Toggle("Menu Bar Only", isOn: menuBarOnlyBinding)

        Divider()

        Button("Quit Rack") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// "Running — MacBook Pro Speakers", or just the state when there is no
    /// device to name yet.
    private var statusLine: String {
        let state = engine.status.displayName.capitalized
        guard engine.status.isRunning, engine.readout.deviceName != "—" else {
            return state
        }
        return "\(state) — \(engine.readout.deviceName)"
    }

    // Bindings rather than `Button`s with a label that changes, so the items
    // carry the checkmark a menu uses to show state. Each writes through the
    // same property the front panel's own control does — there is one piece of
    // state per setting, and two surfaces onto it.

    private var bypassBinding: Binding<Bool> {
        Binding(get: { engine.isBypassed }, set: { engine.isBypassed = $0 })
    }

    private var standbyBinding: Binding<Bool> {
        Binding(get: { engine.isDisplayIdle }, set: { _ in engine.toggleDisplayIdle() })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { engine.opensAtLogin }, set: { engine.setOpensAtLogin($0) })
    }

    private var menuBarOnlyBinding: Binding<Bool> {
        Binding(get: { engine.isMenuBarOnly }, set: { engine.isMenuBarOnly = $0 })
    }
}

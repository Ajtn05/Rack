import AppKit

/// Dock activation policy, the login item, and the global hotkeys — the
/// parts of the engine that are about how Rack presents itself as an
/// application, not about the audio engine itself.
///
/// The state these methods act on (`hotKeys`, `showWindow`, `opensAtLogin`,
/// `isMenuBarOnly`) stays declared on the class itself — Swift does not allow
/// an extension, in this file or any other, to add a stored property — but
/// nothing here reaches into `tap` or the poll loop, and nothing outside
/// this file calls `applyActivationPolicy`, so the *behaviour* is as
/// self-contained as the state allows.
extension EngineController {
    /// Ask the system to add or remove the login item, then report what it
    /// actually did. A registration the system refuses leaves this false, so
    /// the switch springs back rather than claiming something that will not
    /// happen.
    public func setOpensAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        opensAtLogin = LoginItem.isEnabled
    }

    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(isMenuBarOnly ? .accessory : .regular)
    }

    /// Register the global shortcuts. Separate from `init` because it hands
    /// out a closure over `self`, and because the App target may want the
    /// object graph built before anything system-wide starts firing into it.
    public func startShell() {
        // Here rather than in `init`, which runs before `NSApplication` is
        // created — asking a nil application for its activation policy is a
        // crash on launch, and was one.
        applyActivationPolicy()
        hotKeys.start { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleBypass: self.isBypassed.toggle()
            case .togglePower: self.toggle()
            case .showWindow:
                NSApplication.shared.activate(ignoringOtherApps: true)
                self.showWindow?()
            }
        }
    }

    /// The legend a menu prints beside each shortcut, read from the monitor so
    /// the menu and the registration cannot disagree.
    public func shortcutLegend(for action: HotKeyMonitor.Action) -> String {
        action.shortcutLegend
    }
}

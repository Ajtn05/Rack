import AppCore
import AppKit
import SwiftUI

/// The executable target is wiring only: it owns `@main`, the scene graph, and
/// the object graph handed to AppCore. Screens live in AppCore; the vocabulary
/// they are drawn with lives in DesignSystem.
@main
struct RackApp: App {
    @NSApplicationDelegateAdaptor(RackAppDelegate.self) private var delegate
    @State private var engine = EngineController()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // `Window`, not `WindowGroup`: a rack is one instance. Two windows onto
        // one amplifier would be two sets of meters reading the same engine and
        // two places to change the same setting, which is a way to make a
        // control look broken — the other window's copy does not move.
        Window("Rack", id: Self.windowID) {
            RackScreen(engine: engine)
                .task {
                    // The App target is the only layer that knows what a scene
                    // is, so it is the one that hands AppCore a way to ask for
                    // its window back. The hot keys and the menu bar item both
                    // route through here.
                    engine.showWindow = {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        openWindow(id: Self.windowID)
                    }
                    engine.startShell()
                }
        }
        // Standard chrome sat as a band of system grey across the top of a dark
        // rack and made the window read as a picture of equipment inside a
        // window, rather than as the equipment. Hidden, the panels run to the
        // top edge; `windowTopInset` is what keeps the first one clear of the
        // traffic lights.
        .windowStyle(.hiddenTitleBar)
        // Wide and short, like the hardware: the equalizer and its analyzer set
        // the width, and the panels beside each other set the height.
        .defaultSize(width: 1_020, height: 800)
        // `RackScreen` sets its own floor with `.frame(minWidth:)` — the
        // point below which the amplifier's row of controls outgrows its own
        // panel padding. `.automatic` does not reliably hold a content-driven
        // minimum against a user drag, so this asks for that explicitly.
        .windowResizability(.contentSize)

        // The primary surface for an always-on utility. Rack processes every
        // sound the Mac makes whether or not a window is open, so the window
        // being the only way to reach it was the wrong shape: closing it used
        // to take the amplifier with it.
        //
        // `MenuBarGlyph`, not an SF Symbol: nothing else in this codebase
        // names a system icon — the whole UI is drawn from primitives against
        // theme tokens — and a symbol here would be the first appearance
        // literal to escape `DesignSystem/Themes/`. It is a vector, drawn the
        // same "code, not an imported asset" way as everything else Rack
        // shows, in keeping with that same rule rather than an exception to
        // it. "Rack" stays as the label's accessible name for VoiceOver and
        // the status item's tooltip; it just is not drawn as text any more.
        MenuBarExtra {
            MenuBarScreen(engine: engine)
        } label: {
            MenuBarGlyph()
                .accessibilityLabel("Rack")
        }
    }

    /// The rack window's scene id. One constant, named once, so the scene that
    /// declares it and the call that reopens it cannot drift apart.
    private static let windowID = "rack"
}

/// The one thing SwiftUI's scene graph cannot say on its own.
///
/// Without this, closing the window quits Rack — and quitting Rack tears down
/// the process tap, which un-mutes every application and drops the whole DSP
/// chain out of the signal path. For a utility that is *meant* to keep running
/// with no window open, "the user closed the window" and "the user is finished
/// with the amplifier" are not the same event, and only `Quit` means the
/// second one.
final class RackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A window's frame — restored from the last quit, or just wherever it
    /// happened to be left — is only ever valid for the screen layout it was
    /// last on. Unplug the external display it was positioned across and the
    /// same x, y and width can put a real fraction of the window past the
    /// edge of whatever screen is left, with no drag available to pull it
    /// back since the title bar sliver that would let you grab it is itself
    /// off-screen.
    ///
    /// `constrainFrameRect(_:to:)` is Cocoa's own answer to exactly this —
    /// hand back a frame guaranteed to sit inside a screen's visible area —
    /// applied whenever a window becomes key (covers launch and reopening
    /// from the menu bar) and whenever the screen layout itself changes under
    /// an already-open window (covers unplugging while Rack keeps running).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Selector-based, not the closure form: a `Notification` carries an
        // `Any?` payload, which is not `Sendable`, and a closure captured
        // across `NotificationCenter`'s `@Sendable` callback type fights
        // Swift 6's strict concurrency checker over that even though
        // `queue: .main` already guarantees it never actually leaves the
        // main thread. Objective-C selector dispatch is not statically
        // checked the same way, which is what actually sidesteps it —
        // not a workaround so much as the ordinary way this has always
        // been done.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // `@MainActor` here is a statement to the compiler, not a change of
    // behaviour: `@objc` selector dispatch from `NotificationCenter` is not
    // statically checked from the caller's side, so nothing enforced this
    // before, but every notification these two observe — a window becoming
    // key, the screen layout changing — is already posted on the main thread
    // by AppKit itself. This is what lets the body call `NSWindow` and
    // `NSScreen` APIs without the compiler treating them as a cross-actor
    // hazard they were never actually going to be.
    @objc @MainActor private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.constrainToVisibleScreen(window)
    }

    @objc @MainActor private func screenParametersDidChange(_ notification: Notification) {
        NSApp.windows.forEach(Self.constrainToVisibleScreen)
    }

    @MainActor
    private static func constrainToVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let constrained = window.constrainFrameRect(window.frame, to: screen)
        guard constrained != window.frame else { return }
        window.setFrame(constrained, display: true)
    }
}

import AppKit
import Carbon.HIToolbox
import os

/// System-wide keyboard shortcuts, live whether or not Rack is frontmost.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`,
/// and the difference is the whole reason: a global `NSEvent` monitor needs the
/// user to grant Accessibility control in System Settings — a heavyweight,
/// alarming permission for a volume key — while `RegisterEventHotKey` needs
/// nothing at all. It is old API, and it is the API that does this job without
/// asking to watch every keystroke on the machine.
///
/// The shortcuts are a fixed set rather than user-configurable. A recorder UI,
/// conflict detection against other apps, and persistence for all of it is a
/// feature in its own right; three chords that do the three things worth doing
/// from another application is what earns its keep first.
@MainActor
public final class HotKeyMonitor {
    /// What a shortcut does. The raw value is the hotkey's own id as far as
    /// Carbon is concerned, so it must be stable and non-zero.
    public enum Action: UInt32, CaseIterable, Sendable {
        case toggleBypass = 1
        case togglePower = 2
        case showWindow = 3

        /// `kVK_ANSI_*`. Chosen to spell what they do — B for bypass, P for
        /// power, R for Rack — because a shortcut nobody can remember is a
        /// shortcut nobody uses.
        var keyCode: UInt32 {
            switch self {
            case .toggleBypass: UInt32(kVK_ANSI_B)
            case .togglePower: UInt32(kVK_ANSI_P)
            case .showWindow: UInt32(kVK_ANSI_R)
            }
        }

        /// ⌥⌘ for all three. Command alone collides with everything, and
        /// ⌃⌥⌘ is a chord nobody plays by accident *or* on purpose.
        var modifiers: UInt32 { UInt32(optionKey | cmdKey) }

        /// How the menu spells it, so the menu and the registration cannot
        /// drift apart — both read this.
        public var shortcutLegend: String {
            switch self {
            case .toggleBypass: "⌥⌘B"
            case .togglePower: "⌥⌘P"
            case .showWindow: "⌥⌘R"
            }
        }
    }

    private static let log = Logger(subsystem: "dev.rack.Rack", category: "hotkeys")

    /// `'RACK'` as a four-character code — the signature half of every hotkey
    /// id we register, so ours are distinguishable from any other app's.
    private static let signature: OSType = 0x5241_434B

    /// What to run when a shortcut fires. Static because the Carbon callback
    /// below is a C function pointer and cannot capture context — the id that
    /// comes back through the event is the only thing tying an event to an
    /// action, so the table has to be reachable without a `self`.
    private static var handlers: [UInt32: (Action) -> Void] = [:]

    private var registrations: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    public init() {}

    deinit {
        // `stop()` is main-actor isolated and deinit is not; the references
        // are cleaned up by the process exiting, which is the only way a
        // monitor that lives as long as the app ever goes away.
    }

    /// Register every shortcut and start listening. A second call is a no-op —
    /// registering the same chord twice would have Carbon fire it twice.
    public func start(_ perform: @escaping (Action) -> Void) {
        guard eventHandler == nil else { return }

        Self.handlers = Dictionary(
            uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, perform) }
        )

        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // A bare C function: no captures, so it can be a function pointer. The
        // event carries the id, and the id is the whole of the context.
        let callback: EventHandlerUPP = { _, event, _ in
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &identifier
            )
            guard status == noErr, identifier.signature == HotKeyMonitor.signature else {
                return status
            }
            HotKeyMonitor.fire(identifier.id)
            return noErr
        }

        let installed = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &specification, nil, &eventHandler
        )
        guard installed == noErr else {
            Self.log.error("hot key handler failed to install — \(installed, privacy: .public)")
            return
        }

        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode, action.modifiers, identifier,
                GetApplicationEventTarget(), 0, &reference
            )
            // A chord another application already owns fails here, and that is
            // not fatal: the other two still work, and the user still has every
            // control on the front panel. Logged rather than surfaced, because
            // a dialog about a keyboard shortcut at launch is worse than the
            // shortcut quietly not being ours.
            if status == noErr, let reference {
                registrations.append(reference)
            } else {
                Self.log.notice(
                    """
                    hot key \(action.shortcutLegend, privacy: .public) unavailable \
                    — \(status, privacy: .public), probably taken by another app
                    """
                )
            }
        }
    }

    /// Hand every shortcut back to the system.
    public func stop() {
        for reference in registrations {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        Self.handlers = [:]
    }

    /// Carbon calls its handler on the main thread, but that is a promise made
    /// by the run loop rather than one the compiler knows about — hence the
    /// explicit hop rather than an assumption.
    private nonisolated static func fire(_ rawIdentifier: UInt32) {
        Task { @MainActor in
            guard let action = Action(rawValue: rawIdentifier),
                  let perform = handlers[rawIdentifier]
            else { return }
            perform(action)
        }
    }
}

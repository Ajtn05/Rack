import AppKit
import Foundation

/// Reports which application is frontmost, for rules that switch on it.
///
/// The only reason AppCore touches AppKit. It is kept to this one file and
/// behind a callback so the rule engine itself stays pure — `RuleEngine` takes
/// a `RuleContext` and knows nothing about how it was filled in, which is what
/// lets it be tested without a window server.
@MainActor
final class ForegroundAppMonitor {
    var onChange: ((String?) -> Void)?

    /// `nonisolated(unsafe)` so `deinit`, which is not main-actor isolated,
    /// can remove the observer. Safe for the usual reason: deinit runs only
    /// once the last reference is gone. Every other access is on the main
    /// actor.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    var currentBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let bundleID = application?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.onChange?(bundleID)
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

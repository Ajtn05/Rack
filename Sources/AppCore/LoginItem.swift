import Foundation
import ServiceManagement
import os

/// Whether Rack starts itself when the user logs in.
///
/// `SMAppService.mainApp` rather than a separate launcher helper: Rack *is*
/// the thing that should start, and a helper would be a second binary to sign,
/// a second thing to keep in step with the app it launches, and a second place
/// for the registration to be wrong.
///
/// The system owns this state, not `state.json`. A login item registered in
/// System Settings and a login item registered here are the same fact, and
/// keeping our own copy of it would mean a file that disagrees with the system
/// the first time someone turns it off in Settings instead of in Rack. So the
/// status is always *read back* from `SMAppService` rather than remembered.
public enum LoginItem {
    private static let log = Logger(subsystem: "dev.rack.Rack", category: "loginitem")

    /// Whether the system currently has Rack registered to open at login.
    ///
    /// `.enabled` only — `.requiresApproval` means the user has to allow it in
    /// System Settings before it will actually happen, and reporting that as
    /// "on" would be a switch that says yes while nothing starts.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the registration went through but is waiting on the user to
    /// approve it in System Settings > General > Login Items. Worth telling
    /// them apart: nothing Rack does can clear this one.
    public static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister, reporting whether it actually worked.
    ///
    /// This is a real system call that can genuinely fail — an unsigned or
    /// quarantined build, a user who has denied it — so the result is returned
    /// rather than assumed. The caller re-reads `isEnabled` instead of trusting
    /// what it asked for, which is what makes the toggle spring back rather
    /// than lie when registration was refused.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Registering something already registered throws rather than
                // being a no-op, and that is not a failure worth reporting.
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            log.error(
                """
                login item \(enabled ? "registration" : "removal", privacy: .public) failed \
                — \(String(describing: error), privacy: .public)
                """
            )
            return false
        }
    }
}

import AudioCore
import DesignSystem
import Foundation

/// AppCore owns view models, application state, persistence, and device
/// policy. It is the only module allowed to see both AudioCore and
/// DesignSystem, and it is where the two are joined: audio values in,
/// theme-agnostic view data out.
public enum AppCore {
    public static let version = "0.0.1"
}

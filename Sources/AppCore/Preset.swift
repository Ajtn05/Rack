import AudioCore
import Foundation

/// A named set of DSP settings.
///
/// Exactly `DSPParameters` plus a name, which is why Phase 2 put every
/// tunable value into one `Codable` struct. A preset is not a special format;
/// it is the engine's own state written down.
public struct Preset: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var parameters: DSPParameters

    /// For stable ordering. Presets are shown newest-last so a saved preset
    /// appears where the user left it rather than jumping around.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parameters: DSPParameters,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.createdAt = createdAt
    }
}

// MARK: - Auto-switching

/// When a rule applies.
///
/// Deliberately a small closed set. The brief asks for a dumb, declarative
/// engine, and a dumb engine is one whose behaviour a user can predict from
/// reading the list — not one with a query language.
public enum RuleCondition: Equatable, Sendable, Codable {
    /// The stable identifier of the output device. Matched exactly.
    case outputDevice(uid: String)

    /// A substring of the device's name, for the case where the UID is
    /// unhelpful — Bluetooth UIDs are opaque and vary by pairing.
    case outputDeviceNameContains(String)

    /// The bundle ID of the frontmost application.
    case foregroundApp(bundleID: String)

    /// Always matches. Useful as a final catch-all.
    case always

    public func matches(_ context: RuleContext) -> Bool {
        switch self {
        case .outputDevice(let uid):
            return context.outputDeviceUID == uid
        case .outputDeviceNameContains(let fragment):
            guard let name = context.outputDeviceName, !fragment.isEmpty else {
                return false
            }
            return name.localizedCaseInsensitiveContains(fragment)
        case .foregroundApp(let bundleID):
            return context.foregroundAppBundleID == bundleID
        case .always:
            return true
        }
    }

    /// How the rule reads in a list.
    public var summary: String {
        switch self {
        case .outputDevice(let uid): "Output device is \(uid)"
        case .outputDeviceNameContains(let fragment): "Output device name contains “\(fragment)”"
        case .foregroundApp(let bundleID): "Frontmost app is \(bundleID)"
        case .always: "Always"
        }
    }
}

/// What the world looks like right now, as far as the rules care.
public struct RuleContext: Equatable, Sendable {
    public var outputDeviceUID: String?
    public var outputDeviceName: String?
    public var foregroundAppBundleID: String?

    public init(
        outputDeviceUID: String? = nil,
        outputDeviceName: String? = nil,
        foregroundAppBundleID: String? = nil
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.foregroundAppBundleID = foregroundAppBundleID
    }
}

/// One `(condition, preset)` pair.
public struct AutoSwitchRule: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var condition: RuleCondition
    public var presetID: UUID
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        condition: RuleCondition,
        presetID: UUID,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.condition = condition
        self.presetID = presetID
        self.isEnabled = isEnabled
    }
}

/// Evaluates the rule list.
///
/// Top down, first enabled match wins, and that is the whole algorithm. No
/// specificity scoring, no combining, no precedence beyond list order — if two
/// rules could both apply, the one higher up is the one that does, and the
/// user fixes it by dragging. Anything cleverer is a system whose behaviour has
/// to be explained rather than read.
public enum RuleEngine {
    public static func matchingPreset(
        in rules: [AutoSwitchRule],
        for context: RuleContext,
        knownPresets: [Preset]
    ) -> UUID? {
        for rule in rules where rule.isEnabled {
            guard rule.condition.matches(context) else { continue }
            // A rule pointing at a deleted preset is skipped rather than
            // stopping evaluation: the user's intent was to switch to
            // something, and the next rule is a better guess than nothing.
            guard knownPresets.contains(where: { $0.id == rule.presetID }) else {
                continue
            }
            return rule.presetID
        }
        return nil
    }
}

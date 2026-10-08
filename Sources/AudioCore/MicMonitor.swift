import CoreAudio
import Foundation

/// Live microphone monitoring: a physical input mixed into the output
/// alongside everything else Rack is already carrying.
///
/// Kept out of `DSPParameters` for the same reason `AppMix` is. A preset is a
/// sound worth sharing; "the USB interface at 40% on this Mac" is a property
/// of this machine right now, and loading someone else's preset must not
/// silently switch a microphone on.
///
/// Off by default, deliberately. Monitoring a mic through *speakers* rather
/// than headphones is an acoustic feedback loop waiting to happen — the mic
/// hears the speakers, which makes the mic louder, which makes the speakers
/// louder. The limiter at the end of the chain bounds how bad that gets, but
/// bounding a howl is not the same as preventing one, so the feature starts
/// switched off and the panel says so.
public struct MicMonitor: Equatable, Sendable, Codable {
    /// Whether the microphone is in the signal path at all.
    ///
    /// Distinct from `isMuted` below, and not merely a second way to say the
    /// same thing: this one governs whether the device is part of the
    /// aggregate, which costs a rebuild to change. Mute is a gain of zero on
    /// a path that stays built, which costs nothing. A monitoring feature
    /// needs both — "not right now" and "not at all" are different answers.
    public var isEnabled: Bool

    /// Which input device, by UID.
    ///
    /// A UID rather than an `AudioObjectID` for the reason
    /// `AutoSwitchRule` already keys on one: object IDs are reassigned when a
    /// device reconnects, so a saved selection stored as an ID would attach
    /// to whatever hardware happened to inherit the number. Nil means "the
    /// system default input", which is what someone who has never opened the
    /// picker means.
    public var deviceUID: String?

    /// 0…1.
    public var volume: Double

    public var isMuted: Bool

    /// Whether to hold the monitor closed when the output is a loudspeaker.
    ///
    /// On by default, because the loop it prevents is the one thing this
    /// feature can do that the user did not ask for. Defeatable, because a
    /// guard with no override is worse than no guard: someone with monitors
    /// across the room at a sensible level has a perfectly good reason to
    /// overrule it, and an app that simply refuses is one they will work around
    /// by turning the whole feature off.
    ///
    /// It governs only the *certain* case — an output macOS names as a speaker.
    /// Everything else is left to the howl detector, which does not have to
    /// guess in advance. See `FeedbackRisk`.
    public var isFeedbackGuardEnabled: Bool

    public init(
        isEnabled: Bool = false,
        deviceUID: String? = nil,
        volume: Double = 0.5,
        isMuted: Bool = false,
        isFeedbackGuardEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.deviceUID = deviceUID
        self.volume = volume
        self.isMuted = isMuted
        self.isFeedbackGuardEnabled = isFeedbackGuardEnabled
    }

    /// Decoded leniently: a saved monitor written before the guard existed
    /// must come back with it **on**, not off. A missing key is the absence of
    /// an opinion, and the safe reading of that is the default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        deviceUID = try container.decodeIfPresent(String.self, forKey: .deviceUID)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isFeedbackGuardEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .isFeedbackGuardEnabled) ?? true
    }

    /// Square-law, matching the master volume and the per-application faders
    /// so every fader in the program behaves the same way under the hand.
    ///
    /// Zero whenever the monitor is switched off, not merely when muted: a
    /// disabled monitor whose stream is somehow still present must contribute
    /// silence rather than its last level.
    public var gain: Double {
        guard isEnabled, !isMuted, volume > 0 else { return 0 }
        let clamped = min(max(volume, 0), 1)
        return clamped * clamped
    }

    /// Whether a change from `other` needs the whole capture path rebuilt, as
    /// opposed to a republish that costs nothing.
    ///
    /// The same distinction `AppMix` draws between changing an application's
    /// volume and changing *which* applications are controlled: the set of
    /// devices in the aggregate is structural, the gains applied to them are
    /// not.
    /// Whether a change from `other` needs the whole capture path rebuilt.
    ///
    /// The guard is on this list because switching it changes whether the
    /// microphone is a sub-device of the aggregate at all — held, it is left
    /// out entirely rather than included at a gain of zero. That is the
    /// difference between the recording indicator being lit and not, and
    /// between spending one of the sixteen stream slots and not.
    public func needsRebuild(comparedTo other: MicMonitor) -> Bool {
        isEnabled != other.isEnabled
            || deviceUID != other.deviceUID
            || isFeedbackGuardEnabled != other.isFeedbackGuardEnabled
    }
}

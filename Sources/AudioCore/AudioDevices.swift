import CoreAudio
import Foundation

/// A device audio can be sent to.
public struct OutputDeviceInfo: Identifiable, Equatable, Sendable {
    public let objectID: AudioObjectID
    /// Stable across relaunches; what auto-switch rules match on.
    public let uid: String
    public let name: String
    public let channelCount: Int
    public let sampleRate: Double

    public var id: String { uid }

    public init(
        objectID: AudioObjectID,
        uid: String,
        name: String,
        channelCount: Int,
        sampleRate: Double
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}

/// A device audio can be captured from.
public struct InputDeviceInfo: Identifiable, Equatable, Sendable {
    public let objectID: AudioObjectID
    /// Stable across relaunches; what the mic monitor's saved selection
    /// matches on, the same way `OutputDeviceInfo.uid` is used for output.
    public let uid: String
    public let name: String
    public let channelCount: Int
    public let sampleRate: Double

    public var id: String { uid }

    public init(
        objectID: AudioObjectID,
        uid: String,
        name: String,
        channelCount: Int,
        sampleRate: Double
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}

/// Facts about output devices, and the one thing Rack changes about them.
public enum AudioDevices {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Every UID Rack gives its own private aggregate starts with this. The
    /// one place that string is spelled out; `TapSession` builds a UID from it
    /// and this file checks for it, and neither may drift from the other.
    static let rackAggregateUIDPrefix = "dev.rack.aggregate."

    /// The device the system is currently sending audio to.
    static func defaultOutputDevice() throws -> AudioObjectID {
        let id: AudioObjectID = try AudioProperty.read(
            systemObject,
            AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
            context: "finding the default output device"
        )
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(
                operation: "AudioObjectGetPropertyData",
                status: kAudioHardwareBadDeviceError,
                context: "finding the default output device — the system reports none"
            )
        }
        return id
    }

    /// The input device a `MicMonitor` selection resolves to: the one whose
    /// UID matches, or the system default when nothing is named.
    ///
    /// Resolved live, against the device list *now*, for the same reason
    /// `SystemAudioTap.selectOutputDevice` re-resolves rather than trusting a
    /// cached object ID — a UID saved last week is still valid, an object ID
    /// from ten seconds ago may not be. Returns nil when a named device is
    /// gone, which is not an error: the monitor simply has nothing to capture
    /// until the interface is plugged back in.
    static func inputDevice(uid: String?) -> AudioObjectID? {
        guard let uid else { return try? defaultInputDevice() }
        return inputDevices().first { $0.uid == uid }?.objectID
    }

    /// The device the system currently reads microphone input from.
    static func defaultInputDevice() throws -> AudioObjectID {
        let id: AudioObjectID = try AudioProperty.read(
            systemObject,
            AudioProperty.address(kAudioHardwarePropertyDefaultInputDevice),
            context: "finding the default input device"
        )
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(
                operation: "AudioObjectGetPropertyData",
                status: kAudioHardwareBadDeviceError,
                context: "finding the default input device — the system reports none"
            )
        }
        return id
    }

    /// The stable string identifier for a device. This, not the numeric object
    /// ID, is what an aggregate device description refers to sub-devices by,
    /// and what Phase 5 keys preset auto-switching rules on.
    static func uid(of device: AudioObjectID) throws -> String {
        try AudioProperty.readString(
            device,
            AudioProperty.address(kAudioDevicePropertyDeviceUID),
            context: "reading the device UID"
        )
    }

    static func name(of device: AudioObjectID) throws -> String {
        try AudioProperty.readString(
            device,
            AudioProperty.address(kAudioObjectPropertyName),
            context: "reading the device name"
        )
    }

    static func nominalSampleRate(of device: AudioObjectID) throws -> Double {
        try AudioProperty.read(
            device,
            AudioProperty.address(kAudioDevicePropertyNominalSampleRate),
            context: "reading the device sample rate"
        )
    }

    static func outputChannelCount(of device: AudioObjectID) throws -> Int {
        try AudioProperty.channelCount(
            device,
            scope: kAudioObjectPropertyScopeOutput,
            context: "reading the output channel count"
        )
    }

    static func inputChannelCount(of device: AudioObjectID) throws -> Int {
        try AudioProperty.channelCount(
            device,
            scope: kAudioObjectPropertyScopeInput,
            context: "reading the input channel count"
        )
    }

    /// Every device that can play audio.
    ///
    /// Filtered on having output channels, because the device list also
    /// contains input-only hardware and the aggregate devices other
    /// applications have built.
    public static func outputDevices() -> [OutputDeviceInfo] {
        let ids: [AudioObjectID]
        do {
            ids = try AudioProperty.readArray(
                systemObject,
                AudioProperty.address(kAudioHardwarePropertyDevices),
                of: AudioObjectID.self,
                context: "listing audio devices"
            )
        } catch {
            return []
        }

        return ids.compactMap { id in
            guard let channels = try? outputChannelCount(of: id), channels > 0,
                  let uid = try? uid(of: id),
                  let name = try? name(of: id)
            else { return nil }

            // Two ways a device can lead back to us: it *is* our aggregate —
            // a stale one from a previous run could linger — or it is a
            // multi-output device that *contains* our aggregate as one of its
            // members, which routes audio into our own capture path just as
            // surely. The second case has to be found by walking the
            // membership rather than by name, because nothing about the
            // containing device's own name or UID says so.
            guard !isRackLoop(uid: uid, subDeviceUIDs: aggregateSubDeviceUIDs(of: id))
            else { return nil }

            return OutputDeviceInfo(
                objectID: id,
                uid: uid,
                name: name,
                channelCount: channels,
                sampleRate: (try? nominalSampleRate(of: id)) ?? 0
            )
        }
    }

    /// Whether selecting a device with this UID and this membership would
    /// route audio back into Rack's own capture path.
    ///
    /// Pure and separate from the Core Audio read below it, the same way
    /// `DeviceChangeDecision.decide` is kept apart from `DeviceMonitor` — so
    /// the one property this depends on (does a rack aggregate's UID appear
    /// anywhere in the membership?) can be checked without a sound card.
    static func isRackLoop(uid: String, subDeviceUIDs: [String]) -> Bool {
        uid.hasPrefix(rackAggregateUIDPrefix)
            || subDeviceUIDs.contains { $0.hasPrefix(rackAggregateUIDPrefix) }
    }

    /// The UIDs of every device folded into an aggregate or multi-output
    /// device, however deeply nested. Empty for ordinary hardware, which has
    /// no such property.
    ///
    /// `kAudioAggregateDevicePropertyFullSubDeviceList` — "full" rather than
    /// the plain sub-device list — is what makes one call enough: Core Audio
    /// already flattens an aggregate built from other aggregates, so a rack
    /// device nested two or three multi-output devices deep still turns up
    /// here without this having to recurse to find it.
    static func aggregateSubDeviceUIDs(of device: AudioObjectID) -> [String] {
        var address = AudioProperty.address(kAudioAggregateDevicePropertyFullSubDeviceList)
        guard AudioObjectHasProperty(device, &address) else { return [] }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        var array: CFArray?
        let status = withUnsafeMutablePointer(to: &array) { pointer -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let array,
              let uids = array as? [String]
        else { return [] }
        return uids
    }

    /// Every device that can capture audio — microphones, line inputs, and
    /// input-capable interfaces.
    ///
    /// Filtered on having input channels, the mirror of `outputDevices()`'s
    /// own filter. A rack aggregate is excluded the same way an output loop
    /// is: it has no input channels of its own to begin with (a private
    /// aggregate's sub-devices are the real output plus, once the mic monitor
    /// exists, the mic itself — not something that should ever be offered
    /// back as a source), but the check is kept anyway rather than assumed,
    /// since nothing prevents a future aggregate shape from having one.
    public static func inputDevices() -> [InputDeviceInfo] {
        let ids: [AudioObjectID]
        do {
            ids = try AudioProperty.readArray(
                systemObject,
                AudioProperty.address(kAudioHardwarePropertyDevices),
                of: AudioObjectID.self,
                context: "listing audio devices"
            )
        } catch {
            return []
        }

        return ids.compactMap { id in
            guard let channels = try? inputChannelCount(of: id), channels > 0,
                  let uid = try? uid(of: id),
                  let name = try? name(of: id)
            else { return nil }

            guard !isRackLoop(uid: uid, subDeviceUIDs: aggregateSubDeviceUIDs(of: id))
            else { return nil }

            return InputDeviceInfo(
                objectID: id,
                uid: uid,
                name: name,
                channelCount: channels,
                sampleRate: (try? nominalSampleRate(of: id)) ?? 0
            )
        }
    }

    /// Make a device the system's output.
    ///
    /// Rack changes the *system* default rather than routing internally,
    /// because that is what the control claims to do: the menu bar volume, the
    /// Sound pane and every other application follow it. Our own device
    /// listener then fires and rebuilds the capture path onto it.
    public static func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        var address = AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = device
        try AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &device
        )
        .orThrow("AudioObjectSetPropertyData", "selecting the output device")
    }

    /// Whether monitoring a microphone into this output can feed back.
    ///
    /// Reads `kAudioDevicePropertyDataSource` in the output scope and hands the
    /// answer to `FeedbackRisk.decide`, which holds the actual rule. Devices
    /// without the property — most external interfaces — report `unknown`,
    /// which is not treated as dangerous; see `FeedbackRisk.unknown`.
    static func feedbackRisk(ofOutput device: AudioObjectID) -> FeedbackRisk {
        FeedbackRisk.decide(
            dataSource: dataSource(of: device, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    /// A device's current data source, as the four-character code Core Audio
    /// reports — `hdpn` for headphones, `ispk` for the internal speaker. Nil
    /// for a device with no such property, which is not an error: plenty of
    /// hardware has exactly one source and does not describe it.
    static func dataSource(
        of device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        let address = AudioProperty.address(
            kAudioDevicePropertyDataSource, scope: scope
        )
        guard AudioProperty.exists(device, address) else { return nil }
        return try? AudioProperty.read(device, address, as: UInt32.self)
    }

    /// Translate a process ID into the audio object that represents it.
    ///
    /// `CATapDescription`'s process list holds **audio object IDs**, not PIDs,
    /// which is easy to miss — passing a raw PID produces a tap that silently
    /// excludes nothing. Returns nil when the process has no audio object,
    /// which is the normal state for a process that has not yet played
    /// anything.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            systemObject,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return objectID
    }
}

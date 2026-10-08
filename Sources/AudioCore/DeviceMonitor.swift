import CoreAudio
import Foundation

/// Watches the system for the changes that invalidate a capture path.
///
/// Core Audio delivers these on a dispatch queue of our choosing — never the
/// audio thread — so everything here is ordinary code. The listener blocks are
/// retained because `AudioObjectRemovePropertyListenerBlock` matches on block
/// identity: hand it a different closure with the same body and the listener
/// stays installed forever.
///
/// This only *reports*. Deciding what a change means, and coalescing the
/// bursts of them that Bluetooth produces, belongs to `SystemAudioTap`.
final class DeviceMonitor: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        /// The system is now sending audio somewhere else.
        case defaultOutputDeviceChanged

        /// The system is now *reading* audio from somewhere else.
        ///
        /// Only interesting while the microphone monitor is following the
        /// system default — which is what it does until someone opens the
        /// picker — but that case was previously invisible: nothing watched
        /// this property, so changing the input in Sound settings left Rack
        /// monitoring whichever device had been default when the session was
        /// built, with no event to notice it by.
        case defaultInputDeviceChanged

        /// A device appeared or disappeared. Not always interesting on its
        /// own, but a device vanishing is how headphones being unplugged
        /// first shows up.
        case deviceListChanged

        /// The device we are attached to changed its sample rate underneath
        /// us, which makes every filter coefficient wrong.
        case sampleRateChanged
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    /// Serial, and deliberately not the main queue: these fire during device
    /// transitions when the main thread may be busy, and ordering matters more
    /// than latency.
    private let queue = DispatchQueue(label: "dev.rack.device-monitor")

    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watchedDevice: AudioObjectID?

    init() {
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        stopAll()
        continuation.finish()
    }

    // MARK: - System-wide

    /// Begin watching the default output device, the default input device, and
    /// the device list.
    func start() {
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice, emitting: .defaultOutputDeviceChanged)
        addSystemListener(kAudioHardwarePropertyDefaultInputDevice, emitting: .defaultInputDeviceChanged)
        addSystemListener(kAudioHardwarePropertyDevices, emitting: .deviceListChanged)
    }

    private func addSystemListener(
        _ selector: AudioObjectPropertySelector,
        emitting event: Event
    ) {
        var address = AudioProperty.address(selector)
        let continuation = self.continuation
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            continuation.yield(event)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioDevices.systemObject, &address, queue, block
        )
        guard status == noErr else { return }
        systemListeners.append((address, block))
    }

    // MARK: - Per-device

    /// Watch a specific device for a sample rate change.
    ///
    /// Called again with a new device after every rebuild; the previous
    /// device's listener is removed first, since it may be about to disappear.
    func watch(device: AudioObjectID) {
        stopWatchingDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }

        var address = AudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        let continuation = self.continuation
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            continuation.yield(.sampleRateChanged)
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        guard status == noErr else { return }

        deviceListeners.append((device, address, block))
        watchedDevice = device
    }

    func stopWatchingDevice() {
        for (device, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        deviceListeners.removeAll()
        watchedDevice = nil
    }

    func stopAll() {
        stopWatchingDevice()
        for (address, block) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioDevices.systemObject, &address, queue, block
            )
        }
        systemListeners.removeAll()
    }
}

// MARK: - What a change means

/// What to do about a change, decided by comparing what we built against what
/// the system now reports.
///
/// Pure, and separated from the plumbing so it can be tested without a sound
/// card: this is the logic that decides whether a burst of Bluetooth
/// notifications is worth tearing an aggregate device down for.
enum DeviceChangeDecision: Equatable, Sendable {
    /// Nothing meaningful changed. The common case — Core Audio emits
    /// notifications for plenty of things that do not affect us.
    case ignore

    /// The output device itself changed. Requires a new tap and aggregate.
    case rebuild

    /// Same device, new sample rate. The coefficients are wrong but the
    /// plumbing is fine, so recompile rather than rebuild — much cheaper, and
    /// it does not interrupt the stream.
    case retune(sampleRate: Double)

    /// Compare the running configuration against the current system state.
    ///
    /// - Parameter runningMicDeviceUID: the microphone actually folded into the
    ///   running aggregate, or nil if it carries none.
    /// - Parameter currentMicDeviceUID: the microphone the monitor's settings
    ///   resolve to *now* — nil when monitoring is off, and also nil when it is
    ///   on but the chosen device is unplugged.
    static func decide(
        runningDeviceUID: String,
        runningSampleRate: Double,
        runningMicDeviceUID: String? = nil,
        currentDeviceUID: String?,
        currentSampleRate: Double?,
        currentMicDeviceUID: String? = nil
    ) -> DeviceChangeDecision {
        // No default output device at all: nothing to rebuild onto. Waiting is
        // right — one usually reappears within a moment, and tearing down here
        // would leave the user with no audio and nothing to switch back to.
        guard let currentDeviceUID, let currentSampleRate else { return .ignore }

        if currentDeviceUID != runningDeviceUID { return .rebuild }

        // Which microphone is in the aggregate is structural in exactly the way
        // the output device is — it is a sub-device, not a gain — so a change
        // costs a rebuild and cannot be retuned around.
        //
        // This is what makes three separate situations resolve themselves that
        // previously did not: the system default input changing underneath a
        // monitor that follows it, the chosen interface being unplugged (which
        // rebuilds to a session with no microphone rather than one wired to a
        // device that is gone), and that interface being plugged back in.
        if currentMicDeviceUID != runningMicDeviceUID { return .rebuild }

        // Sample rates are floating point and arrive from the driver, so
        // compare with a tolerance rather than for equality.
        if abs(currentSampleRate - runningSampleRate) > 0.5 {
            return .retune(sampleRate: currentSampleRate)
        }

        return .ignore
    }
}

// MARK: - Whether a path that built successfully actually works

/// What to do about a capture path that came up without complaint.
///
/// Every Core Audio call returning `noErr` is not the same claim as "audio is
/// moving", and the difference is not academic: a private aggregate created
/// carrying a process tap starts happily and then never runs its IO cycle until
/// one of the tapped processes plays something. `TapSession.attachTaps` fixes
/// that particular cause; this is the general check, because the interesting
/// property is the one the engine asserts — `.running` — rather than any
/// particular way of failing to achieve it.
///
/// Pure, and separated from the actor that acts on it, for exactly the reason
/// `DeviceChangeDecision` is: the rule is the whole of the thing worth getting
/// right, and it should be checkable without a sound card — most of all the
/// bound, which is what stops a check that is wrong from turning into an
/// endless teardown-and-rebuild loop.
enum LivenessVerdict: Equatable, Sendable {
    /// The IOProc is being called. Nothing to do.
    case live

    /// Built, started, and carrying nothing. Rebuild and look again.
    case rebuild

    /// Rebuilding has not helped and will not. Say so rather than keep
    /// claiming to run, and rather than keep tearing the path down.
    case giveUp

    /// - Parameters:
    ///   - buffersBefore: `buffersRendered` when the check began.
    ///   - buffersAfter: the same counter after the observation window.
    ///   - rebuildsAlreadyTried: consecutive rebuilds this check has already
    ///     caused, reset by the first pass.
    ///   - limit: how many of those are allowed before giving up.
    static func decide(
        buffersBefore: UInt64,
        buffersAfter: UInt64,
        rebuildsAlreadyTried: Int,
        limit: Int
    ) -> LivenessVerdict {
        // A single callback is proof. The counter climbs on every IOProc
        // invocation whatever the audio turns out to be, so this asks "is the
        // path running", not "is anything playing" — which matters, because a
        // silent system is perfectly healthy and must not be rebuilt.
        if buffersAfter > buffersBefore { return .live }
        return rebuildsAlreadyTried < limit ? .rebuild : .giveUp
    }
}

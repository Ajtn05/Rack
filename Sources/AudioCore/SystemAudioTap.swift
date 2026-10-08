import CoreAudio
import Foundation

/// Everything a poller wants to know at once — see
/// `SystemAudioTap.deviceSnapshot()`.
public struct DeviceSnapshot: Sendable {
    public let audioProcesses: [AudioProcessInfo]
    public let outputDevices: [OutputDeviceInfo]
    public let inputDevices: [InputDeviceInfo]
    public let controlledApplicationIDs: Set<String>
    public let isMicHeldForFeedback: Bool
}

/// Captures all system audio and renders it to the current output device.
///
/// Phase 1 renders it unchanged. Phase 2 inserts the DSP chain; nothing about
/// this interface changes when it does, which is the point of putting the
/// actor boundary here.
///
///     let tap = SystemAudioTap()
///     Task { for await state in tap.stateChanges { … } }
///     try await tap.start()
///
/// The first `start()` on a machine raises the system's audio-capture
/// permission prompt.
public actor SystemAudioTap {
    /// Where the engine is. `failed` carries the decoded Core Audio error
    /// rather than a bare status.
    public enum State: Sendable, Equatable {
        case idle
        case starting
        case running(RunningInfo)
        case stopped
        case failed(CoreAudioError)
    }

    /// What the path settled on once it was up. Chiefly for showing the user
    /// which device is being processed, and for spotting a format that is not
    /// what we expected.
    public struct RunningInfo: Sendable, Equatable {
        public let outputDeviceName: String
        public let outputDeviceUID: String
        public let sampleRate: Double
        public let outputChannelCount: Int
    }

    /// A snapshot of what the audio thread has been doing. Peak levels are
    /// drained by reading, so successive reads report the peak since the last
    /// look rather than since the engine started.
    public struct Diagnostics: Sendable, Equatable {
        public let framesRendered: UInt64
        public let buffersRendered: UInt64
        public let silentBuffers: UInt64
        public let mismatchedBuffers: UInt64

        /// Channels across the last callback's input buffers — what the tap
        /// and the microphone are actually delivering, as opposed to what the
        /// aggregate device says its streams are. See
        /// `TapRenderContext.inputChannels` for why the two are not the same
        /// question and why this is the one worth showing.
        public let inputChannelCount: Int

        /// Times the chain produced a non-finite sample and bypassed itself.
        /// Should be zero forever; anything else is a bug worth chasing.
        public let dspFaults: UInt64
        public let peakLeft: Float
        public let peakRight: Float

        /// Mean rectified magnitude since the last drain, per channel — the
        /// input a VU ballistic filters, uncalibrated and undecorated, the
        /// same convention `peakLeft`/`peakRight` follow.
        public let vuLeft: Float
        public let vuRight: Float

        /// Phase correlation for the window since the last drain, raw and
        /// unfiltered — `+1` in phase, `0` unrelated, `−1` out of phase. The
        /// same "uncalibrated, undecorated" convention as `peakLeft` and
        /// `vuLeft`: ballistics belong to `AppCore`'s `CorrelationMeter`, not
        /// here.
        public let correlation: Float

        /// The compressor's current gain reduction, in dB, always ≥ 0 —
        /// already the settled reading the audio thread's own attack/release
        /// produced, not a raw value `AppCore` filters further the way
        /// `vuLeft`/`vuRight` are.
        public let compressorReductionDecibels: Float

        /// How far the limiter is holding the output down, in dB, always ≥ 0.
        public let limiterReductionDecibels: Float

        /// How far the howl detector is cutting the microphone, in dB, always
        /// ≥ 0. Zero for any room that never howls.
        public let feedbackDuckDecibels: Float

        /// How many parameter sets have been handed to the engine. Not an
        /// audio statistic — a plumbing one. If this does not move when a
        /// slider is dragged, the fault is above AudioCore, and that is worth
        /// being able to tell at a glance.
        public let publicationCount: UInt64

        public static let zero = Diagnostics(
            framesRendered: 0, buffersRendered: 0, silentBuffers: 0,
            mismatchedBuffers: 0, inputChannelCount: 0, dspFaults: 0,
            peakLeft: 0, peakRight: 0,
            vuLeft: 0, vuRight: 0, correlation: 0, compressorReductionDecibels: 0,
            limiterReductionDecibels: 0, feedbackDuckDecibels: 0,
            publicationCount: 0
        )

    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            continuation.yield(state)
        }
    }

    /// State changes, for a UI to observe.
    ///
    /// Single-consumer, as `AsyncStream` always is. Phase 6 will want more
    /// than one observer and can multiplex here without the engine changing.
    public nonisolated let stateChanges: AsyncStream<State>
    private nonisolated let continuation: AsyncStream<State>.Continuation

    private var session: TapSession?
    private let monitor = DeviceMonitor()

    /// Coalesces device notifications. Cancelled and re-armed by each new
    /// event, so a burst produces one rebuild rather than one per event.
    private var pendingChange: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    /// A device notification arrived while a rebuild was already in flight
    /// and could not be safely acted on there and then.
    ///
    /// Two rebuilds racing each other is worse than the notification it would
    /// have started: `rebuild()` tears the whole path down and puts it back
    /// up, and a second one doing that concurrently is how a session ends up
    /// torn down by one call while the other is still building on top of it.
    /// So a notification that lands mid-rebuild is recorded rather than acted
    /// on, and `rebuild()` checks this the moment it settles — onto whatever
    /// the system's default device actually is *then*, not whatever it was
    /// when the notification first arrived. Without this, a change that
    /// landed mid-rebuild was simply lost: nothing else was going to look
    /// again unless the system happened to repeat itself, which a fast
    /// unplug-replug is exactly the case that does not.
    private var changeArrivedDuringRebuild = false

    /// How long to wait for the dust to settle before acting on a change.
    ///
    /// Bluetooth is the reason this exists. Connecting AirPods emits a stream
    /// of default-device and device-list notifications over a second or so,
    /// and rebuilding on each one means tearing down and recreating an
    /// aggregate device repeatedly while the user waits for sound.
    private static let changeDebounce = Duration.milliseconds(300)

    /// How many times to retry a failed rebuild before giving up.
    ///
    /// A device in transition often refuses for a moment and then works. The
    /// delay grows so that a genuinely absent device is not hammered.
    private static let rebuildAttempts = 4

    // MARK: - Proving it actually runs

    /// Identifies the session a liveness check was started for, so a check
    /// that was in flight when the path was rebuilt underneath it cannot judge
    /// the new one on the old one's evidence.
    private var sessionGeneration = 0

    /// The in-flight liveness check: a task that does nothing but sleep and
    /// then deliver a verdict. Cancelled by anything that replaces the session
    /// it was watching.
    private var livenessTask: Task<Void, Never>?

    /// The rebuild a failed check asked for.
    ///
    /// Deliberately a *different* task from `livenessTask`, and that separation
    /// is not tidiness — it is a bug fix. `rebuild()` begins by cancelling the
    /// liveness task, so a check that called it directly cancelled the very
    /// task it was itself running on; `rebuild()`'s own `Task.isCancelled`
    /// guard then returned immediately, leaving the engine in `.starting` with
    /// no session and nothing left alive to notice. A watchdog that hangs the
    /// thing it is watching is worse than no watchdog, and this is why the
    /// observer only ever observes.
    private var recoveryTask: Task<Void, Never>?

    /// Consecutive checks that found a path built successfully and carrying
    /// nothing. Reset by the first one that passes.
    private var deadPathRebuilds = 0

    /// How long to watch `buffersRendered` before concluding nothing is
    /// happening.
    ///
    /// Deliberately far longer than it takes a running device to prove itself.
    /// A live path delivers a callback every ten milliseconds or so, meaning it
    /// clears this bar roughly two hundred times over; the window is not sized
    /// for how long *success* takes but for how long the slowest legitimate
    /// **start** takes. Starting an aggregate over the built-in speakers has to
    /// wake an amplifier, and at 400 ms this check rebuilt perfectly healthy
    /// sessions that were merely still spinning up — a false positive that
    /// costs an audio gap and, repeated, ends in a spurious fault.
    ///
    /// A safety net does not need to be fast. Two seconds of silence before
    /// recovery begins is a far better trade than tearing down a path that was
    /// about to work.
    private static let livenessWindow = Duration.seconds(2)

    /// How many times to rebuild a path that comes up dead before saying so.
    ///
    /// The bound is the whole safety of this mechanism. A check that is wrong —
    /// or a machine where callbacks legitimately stop — must cost a few gaps
    /// and then a visible fault, never an endless teardown-and-rebuild loop,
    /// which would be considerably worse than the condition it is chasing.
    private static let deadPathRebuildLimit = 2

    /// Start watching the session just built, replacing any check already
    /// running.
    ///
    /// Called from every path that produces a running engine — a cold start, a
    /// rebuild, and a retune — because all three end with the same claim, and
    /// it is the claim rather than any particular route to it that is worth
    /// checking.
    private func scheduleLivenessCheck() {
        livenessTask?.cancel()
        guard let session else { return }
        let generation = sessionGeneration
        // Sampled here, before the task exists, so the window measured is the
        // window slept rather than that plus whatever scheduling delay the
        // task happened to see.
        let before = session.context.buffersRendered

        livenessTask = Task { [weak self] in
            try? await Task.sleep(for: Self.livenessWindow)
            guard !Task.isCancelled else { return }
            await self?.judgeLiveness(generation: generation, buffersBefore: before)
        }
    }

    /// Confirm the IOProc is actually being called, and rebuild if it is not.
    ///
    /// `.running` used to mean "every Core Audio call returned `noErr`", and
    /// the two are not the same thing. A private aggregate created carrying a
    /// process tap starts without complaint and then never runs its IO cycle
    /// until one of the tapped processes happens to play something — see
    /// `TapSession.attachTaps`, which is the fix for that specific cause. This
    /// is the general form: whatever the reason, an engine that reports itself
    /// running while `buffersRendered` never moves is lying, and the counter
    /// that proves it was already being kept.
    ///
    /// Deliberately not part of `start()`. Announcing `.running` and *then*
    /// checking keeps the window responsive and the failure honest — the state
    /// is corrected by evidence a moment later rather than every start being
    /// held back by the length of the window.
    /// Deliver the verdict. Synchronous by design: it must not still be
    /// running when the recovery it asks for begins, or it would be running
    /// inside the task `rebuild()` cancels — see `recoveryTask`.
    private func judgeLiveness(generation: Int, buffersBefore before: UInt64) {
        // The actor is reentrant, so anything at all may have happened during
        // the window — a device change, a rebuild, the user switching the
        // engine off. Every one of those makes this check's evidence stale,
        // and the generation is what catches it.
        guard sessionGeneration == generation,
              let session, case .running = state
        else { return }

        switch LivenessVerdict.decide(
            buffersBefore: before,
            buffersAfter: session.context.buffersRendered,
            rebuildsAlreadyTried: deadPathRebuilds,
            limit: Self.deadPathRebuildLimit
        ) {
        case .live:
            deadPathRebuilds = 0

        case .rebuild:
            deadPathRebuilds += 1
            // Handed to a task of its own, and this one is finished. See
            // `recoveryTask` for what happens if these two are the same task.
            livenessTask = nil
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in await self?.rebuild() }

        case .giveUp:
            state = .failed(
                CoreAudioError(
                    operation: "SystemAudioTap.confirmAudioIsFlowing",
                    status: kAudioHardwareNotRunningError,
                    context: """
                        the aggregate device started but its IOProc was never \
                        called, and rebuilding it \(Self.deadPathRebuildLimit) \
                        time(s) did not change that
                        """
                )
            )
        }
    }

    public init() {
        let (stream, continuation) = AsyncStream<State>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.stateChanges = stream
        self.continuation = continuation
    }

    deinit {
        pendingChange?.cancel()
        monitorTask?.cancel()
        monitor.stopAll()
        continuation.finish()
    }

    // MARK: - Control

    /// Build the capture path and start rendering.
    ///
    /// Idempotent: calling this while already running does nothing.
    public func start() throws {
        if case .running = state { return }
        if case .starting = state { return }
        state = .starting

        do {
            attach(try establishSession())
        } catch let error as CoreAudioError {
            session = nil
            state = .failed(error)
            throw error
        } catch {
            session = nil
            let wrapped = CoreAudioError(
                operation: "SystemAudioTap.start",
                status: kAudioHardwareUnspecifiedError,
                context: error.localizedDescription
            )
            state = .failed(wrapped)
            throw wrapped
        }
    }

    /// Create, publish, and start a session — the part of bring-up that can
    /// fail. Shared by `start()` and `rebuild()`, which differ only in how
    /// they respond to that failure (`start()` throws once; `rebuild()`
    /// retries with backoff).
    private func establishSession() throws -> TapSession {
        let session = try TapSession.create(
            controlling: appMix.controlledProcessObjects(among: AudioProcesses.all()),
            micInputDevice: micDeviceForSession()
        )
        // Publish before starting, so the first buffer already has the
        // right coefficients rather than a buffer of flat audio.
        session.publish(parameters, appMix: appMix, micMonitor: micMonitor)
        try session.start()
        return session
    }

    /// Adopt a session that has already started: wire it in as the current
    /// one, bump the generation, carry over the analyzer's enable flags,
    /// start watching its device, and report `.running`. The rest of
    /// bring-up, shared by `start()` and `rebuild()`.
    ///
    /// Routes through `beginMonitoring` rather than a bare `monitor.watch`
    /// even on the rebuild path: `beginMonitoring` only starts `monitorTask`
    /// when one is not already running, so calling it here is safe whether
    /// this is the first session or the tenth, and it means both callers
    /// get the same guarantee instead of `rebuild()` depending on `start()`
    /// having already set the task up.
    private func attach(_ session: TapSession) {
        self.session = session
        sessionGeneration &+= 1
        session.spectrum.isEnabled = isSpectrumEnabled
        session.goniometerRing.isEnabled = isGoniometerEnabled
        beginMonitoring(session)
        state = .running(runningInfo(for: session))
        scheduleLivenessCheck()
    }

    /// The device the mic monitor should capture from right now, or nil when
    /// monitoring is switched off (or the saved device is unplugged).
    ///
    /// Resolved at build time rather than stored, so a session always folds
    /// in whatever the UID currently names — the same live-resolution
    /// reasoning `selectOutputDevice` documents.
    private func micDeviceForSession() -> AudioObjectID? {
        guard micMonitor.isEnabled, !isFeedbackHeld else { return nil }
        return AudioDevices.inputDevice(uid: micMonitor.deviceUID)
    }

    /// Whether the microphone is being kept out of the aggregate because the
    /// output is a loudspeaker — see `FeedbackRisk`.
    ///
    /// Left *out* rather than included at a gain of zero, deliberately. A mic
    /// that is in the aggregate is a mic being captured as far as the system is
    /// concerned: the recording indicator lights, and one of the sixteen stream
    /// slots is spent, both for a signal nobody can hear. Held, none of that
    /// happens.
    ///
    /// Resolved live rather than stored, the same reasoning `micDeviceForSession`
    /// documents — and it composes with the device-change decision for free,
    /// because that compares the microphone *actually in the aggregate* against
    /// what this resolves to now. Plugging headphones in therefore releases the
    /// hold and rebuilds with the microphone, with nothing else to write.
    var isFeedbackHeld: Bool {
        guard micMonitor.isEnabled, micMonitor.isFeedbackGuardEnabled else { return false }
        guard let output = try? AudioDevices.defaultOutputDevice() else { return false }
        return AudioDevices.feedbackRisk(ofOutput: output) == .loudspeaker
    }

    /// Tear the path down. Safe to call when not running.
    ///
    /// This must actually happen — until the tap is destroyed the processes it
    /// captured stay muted.
    public func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        monitorTask?.cancel()
        monitorTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        monitor.stopAll()

        session?.tearDown()
        session = nil
        sessionGeneration &+= 1
        state = .stopped
    }

    /// Take the settings restored from the last session — all three of them,
    /// in one call, before anything is built.
    ///
    /// `EngineController` loads `parameters`, `appMix` and `micMonitor` from
    /// `state.json` at launch, and this actor keeps its own copy of each. Only
    /// the microphone was ever pushed across, in a detached task of its own,
    /// and that left two holes worth naming because both present as "Rack does
    /// nothing until you touch something":
    ///
    /// - The restored parameters never arrived at all, so the first session
    ///   was built and published from `.flat`. Every knob on screen read the
    ///   user's saved sound and the audio thread rendered a bit-transparent
    ///   passthrough, until any control at all was moved and `setParameters`
    ///   finally published the real values.
    /// - The restored app mix never arrived either, so no application got the
    ///   tap it was supposed to have until its fader was touched.
    ///
    /// One call rather than three also removes the race the single push had:
    /// a detached task and `start()` are ordered by nothing, and a microphone
    /// setting that landed *after* the session was built cost a full rebuild —
    /// destroying and recreating an aggregate device seconds into the launch —
    /// instead of simply being part of what the session was built from.
    ///
    /// Called by `start()` rather than at construction, so every power-on
    /// re-seeds from whatever the controller currently holds and there is no
    /// second path to keep in step.
    public func adopt(
        parameters newParameters: DSPParameters,
        appMix newMix: AppMix,
        micMonitor newMonitor: MicMonitor
    ) async {
        // Decided against the *old* values, before they are overwritten, and
        // only meaningful when something is already running — the common case
        // here is a cold start, where there is nothing to rebuild.
        let needsRebuild =
            newMonitor.needsRebuild(comparedTo: micMonitor)
            || session.map {
                TapSession.boundedProcesses(
                    newMix.controlledProcessObjects(among: AudioProcesses.all()),
                    hasMicrophone: $0.hasMicStream
                ) != $0.requestedProcesses
            } ?? false

        parameters = newParameters
        appMix = newMix
        micMonitor = newMonitor
        publicationCount &+= 1

        guard let session else { return }
        if needsRebuild {
            await rebuild()
        } else {
            session.publish(parameters, appMix: appMix, micMonitor: micMonitor)
        }
    }

    // MARK: - Surviving the real world

    private func runningInfo(for session: TapSession) -> RunningInfo {
        RunningInfo(
            outputDeviceName: session.outputDeviceName,
            outputDeviceUID: session.outputDeviceUID,
            sampleRate: session.sampleRate,
            outputChannelCount: session.outputChannelCount
        )
    }

    private func beginMonitoring(_ session: TapSession) {
        monitor.watch(device: session.outputDeviceID)
        guard monitorTask == nil else { return }
        monitor.start()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.monitor.events {
                await self.deviceStateChanged()
            }
        }
    }

    /// Something changed. Wait for the burst to end, then work out whether it
    /// mattered.
    private func deviceStateChanged() {
        // The pending-change task may itself be rebuilding and sleeping
        // between retries. Cancelling it then strands the engine in .starting.
        if case .starting = state {
            changeArrivedDuringRebuild = true
            return
        }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.applyDeviceChange()
        }
    }

    /// React to a device notification, whatever state we are currently in.
    ///
    /// `.running` is the case with an existing session to compare against, and
    /// is the only one that can tell a real device change from a rate change
    /// worth merely retuning for. `.starting` and `.failed` used to be treated
    /// the same way — ignored — on the theory that only a *running* engine has
    /// anything to react to. That reasoning has a hole: `.starting` means a
    /// rebuild is already trying to reach some device, and `.failed` means the
    /// last one gave up. A notification in either state is not noise, it is
    /// new information — the system telling us something changed again — and
    /// dropping it silently was the whole of the bug where the only way out of
    /// a stuck engine was to power it off and back on by hand.
    private func applyDeviceChange() async {
        switch state {
        case .running:
            guard let session else { return }

            // Read the world as it is now, not as the notification described
            // it — several notifications may have arrived and only the end
            // state counts.
            let currentDevice = try? AudioDevices.defaultOutputDevice()
            let currentUID = currentDevice.flatMap { try? AudioDevices.uid(of: $0) }
            let currentRate = currentDevice.flatMap { try? AudioDevices.nominalSampleRate(of: $0) }
            // Resolved the same way `start()` resolves it, so "what the monitor
            // means right now" is compared against "what is actually in the
            // aggregate" rather than against the saved setting, which does not
            // change when the hardware behind it does.
            let currentMicUID = micDeviceForSession().flatMap { try? AudioDevices.uid(of: $0) }

            switch DeviceChangeDecision.decide(
                runningDeviceUID: session.outputDeviceUID,
                runningSampleRate: session.sampleRate,
                runningMicDeviceUID: session.micInputDeviceUID,
                currentDeviceUID: currentUID,
                currentSampleRate: currentRate,
                currentMicDeviceUID: currentMicUID
            ) {
            case .ignore:
                return
            case .retune(let sampleRate):
                session.retune(
                    to: sampleRate, parameters: parameters,
                    appMix: appMix, micMonitor: micMonitor
                )
                state = .running(runningInfo(for: session))
                // A retune keeps the plumbing, but the device just changed its
                // rate underneath it, which is reason enough to check the
                // stream survived rather than assume it.
                scheduleLivenessCheck()
            case .rebuild:
                await rebuild()
            }

        case .starting:
            changeArrivedDuringRebuild = true

        case .failed:
            // Whatever the last rebuild gave up on, a fresh notification is
            // exactly the signal that the world moved again and is worth one
            // more attempt — a flaky USB interface settling, or the device
            // that failed a moment ago being replaced by another. Bounded by
            // real events rather than a timer: if nothing changes, nothing
            // retries.
            await rebuild()

        case .idle, .stopped:
            // Nothing is meant to be running. A device notification here is
            // not ours to act on — starting the engine is the user's call.
            break
        }
    }

    /// Tear the path down and build a new one on the current default device.
    ///
    /// Teardown comes first. Creating the new tap while the old one still
    /// exists would be quicker, but two taps with `mutedWhenTapped` are live
    /// at once and the aggregate auto-starts its tap on creation, so the
    /// window where both are muting is a window of silence rather than a gap.
    /// A short gap is the better failure.
    private func rebuild() async {
        if case .starting = state {
            changeArrivedDuringRebuild = true
            return
        }
        livenessTask?.cancel()
        livenessTask = nil
        session?.tearDown()
        session = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        state = .starting
        // Only a notification from here on needs a follow-up; one that
        // already caused this very call is spent.
        changeArrivedDuringRebuild = false

        for attempt in 1...Self.rebuildAttempts {
            // stop() or a new start may run while a retry sleeps. The old
            // operation must never resume and replace that newer decision.
            guard !Task.isCancelled, sessionGeneration == generation,
                  case .starting = state else { return }
            do {
                attach(try establishSession())
                await recheckAfterRebuild()
                return
            } catch let error as CoreAudioError {
                // Everything created by the failed attempt has already been
                // destroyed by TapSession.create, so the system is left
                // unmuted between tries. That matters: a device mid-transition
                // often refuses once and works a moment later, and the user
                // should hear normal audio while we wait rather than nothing.
                if attempt == Self.rebuildAttempts {
                    state = .failed(error)
                    await recheckAfterRebuild()
                    return
                }
                try? await Task.sleep(for: .milliseconds(150 * attempt))
            } catch {
                state = .failed(
                    CoreAudioError(
                        operation: "SystemAudioTap.rebuild",
                        status: kAudioHardwareUnspecifiedError,
                        context: error.localizedDescription
                    )
                )
                await recheckAfterRebuild()
                return
            }
        }
    }

    /// The other half of `changeArrivedDuringRebuild`: called the instant a
    /// rebuild settles, successfully or not. If something changed while we
    /// were busy, look again immediately rather than waiting on a fresh
    /// notification that a settled device situation may never send.
    ///
    /// Bounded by construction: this only recurses when the flag was set, and
    /// the flag is only set by an actual Core Audio notification arriving in
    /// between — a quiet system produces no further calls.
    private func recheckAfterRebuild() async {
        guard changeArrivedDuringRebuild else { return }
        changeArrivedDuringRebuild = false
        await applyDeviceChange()
    }

    /// True while audio is being rendered.
    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The panic bypass: routes audio through untouched without going near
    /// parameter compilation. Distinct from `DSPParameters.isBypassed`, which
    /// is the user-facing switch — either one is enough to bypass, so a fault
    /// on one path can never mean silence.
    public var isBypassed: Bool {
        get { session?.context.isBypassed ?? false }
        set { session?.context.isBypassed = newValue }
    }

    /// The current DSP settings.
    public private(set) var parameters: DSPParameters = .flat

    /// Per-application volume and mute.
    public private(set) var appMix = AppMix()

    /// Live microphone monitoring.
    public private(set) var micMonitor = MicMonitor()

    /// Whether the feedback guard is currently holding the microphone out of
    /// the signal path, for a panel that has to explain why the monitor is on
    /// and silent. See `isFeedbackHeld`.
    public func isMicHeldForFeedback() -> Bool { isFeedbackHeld }

    /// Every device audio can be captured from.
    public nonisolated func inputDevices() -> [InputDeviceInfo] {
        AudioDevices.inputDevices()
    }

    /// Apply microphone monitoring settings.
    ///
    /// Switching the monitor on or off, or changing *which* microphone, means
    /// a different set of sub-devices in the aggregate, which means a new
    /// aggregate and a brief gap — the same structural-versus-cosmetic
    /// distinction `setAppMix` draws, and `MicMonitor.needsRebuild` is where
    /// it is decided. Level and mute are a republish and cost nothing.
    public func setMicMonitor(_ newMonitor: MicMonitor) async {
        let previous = micMonitor
        micMonitor = newMonitor

        guard let session else {
            // Nothing live to publish onto. If the engine is sitting `.failed`
            // — most often left there by a device change it could not resolve
            // — switching a microphone on is as good a reason to try again as
            // a fresh device notification, the same reasoning `setAppMix`
            // applies to taking control of an application.
            if case .failed = state { await rebuild() }
            return
        }

        if newMonitor.needsRebuild(comparedTo: previous) {
            await rebuild()
        } else {
            session.publish(parameters, appMix: appMix, micMonitor: micMonitor)
        }
    }

    /// Every device audio can be sent to.
    public nonisolated func outputDevices() -> [OutputDeviceInfo] {
        AudioDevices.outputDevices()
    }

    /// Send system audio somewhere else.
    ///
    /// Changes the system default, so everything follows — then our own
    /// device listener fires and rebuilds the capture path onto it. No special
    /// case here: a device change we caused and one the user made in Sound
    /// settings take exactly the same path.
    ///
    /// Takes the UID rather than an object ID handed in from a caller's own
    /// cache, and re-resolves it against the device list *now*. An object ID
    /// is only stable while the device stays connected — Bluetooth
    /// reconnecting, or a USB interface resetting, hands out a new one — so a
    /// UI holding one from even a couple of seconds ago can be asking Core
    /// Audio to select an object that no longer refers to anything. That call
    /// fails silently rather than doing nothing visibly wrong, which is
    /// indistinguishable from "the switch does not work" — this is the fix
    /// for exactly that report.
    public func selectOutputDevice(uid: String) throws {
        guard let device = AudioDevices.outputDevices().first(where: { $0.uid == uid }) else {
            throw CoreAudioError(
                operation: "SystemAudioTap.selectOutputDevice",
                status: kAudioHardwareBadDeviceError,
                context: "device \(uid) is no longer in the device list"
            )
        }
        try AudioDevices.setDefaultOutputDevice(device.objectID)
    }

    /// The applications that actually have a tap of their own right now.
    ///
    /// Keyed the way `AppMix.Entry` keys itself, so a screen can ask "did this
    /// row's fader really get built?" — which is not the same question as "did
    /// someone ask for it". A per-process tap can fail, and when it does the
    /// application keeps playing through the global tap at its own level. The
    /// panel says so rather than showing a fader that does nothing.
    public func controlledApplicationIDs() -> Set<String> {
        guard let session else { return [] }
        return Set(
            session.controlledProcesses.compactMap { objectID in
                guard let info = AudioProcesses.info(for: objectID) else { return nil }
                return info.bundleID ?? "pid:\(info.processID)"
            }
        )
    }

    /// Every process Core Audio can route audio for. Read on demand rather
    /// than cached: processes come and go, and a stale list is worse than a
    /// slightly expensive one.
    public nonisolated func audioProcesses() -> [AudioProcessInfo] {
        AudioProcesses.all()
    }

    /// Every value a poller needs, gathered in one hop.
    ///
    /// `audioProcesses()`/`outputDevices()`/`inputDevices()` are `nonisolated`
    /// — cheap to call in the sense that they take no lock, but each one does
    /// several Core Audio round trips per device or process. `nonisolated`
    /// means "runs on the caller's executor," so calling them individually
    /// from a `@MainActor` poll loop ran that work on the main thread, every
    /// few seconds, forever. Calling them from in here instead runs them on
    /// this actor's own executor — the isolation of the *caller*, not the
    /// callee, decides where nonisolated code actually runs — so a poller
    /// need only `await` this one method and take a single hop back to
    /// report the result.
    public func deviceSnapshot() -> DeviceSnapshot {
        DeviceSnapshot(
            audioProcesses: audioProcesses(),
            outputDevices: outputDevices(),
            inputDevices: inputDevices(),
            controlledApplicationIDs: controlledApplicationIDs(),
            isMicHeldForFeedback: isMicHeldForFeedback()
        )
    }

    /// Apply per-application settings.
    ///
    /// Changing an application's *volume* is a republish and costs nothing.
    /// Changing which applications are individually controlled means a
    /// different set of taps, which means a new aggregate device — so that
    /// case, and only that case, rebuilds.
    public func setAppMix(_ newMix: AppMix) async {
        appMix = newMix
        guard let session else {
            // No live session to publish onto or rebuild. If the engine is
            // meant to be running but is sitting `.failed` — most often left
            // there by a device change that could not be resolved — taking
            // control of an application is as good a reason to try again as a
            // fresh device notification is. Without this, "Control" on an app
            // row recorded the intent and did nothing audible until the user
            // noticed and power-cycled the engine by hand.
            if case .failed = state { await rebuild() }
            return
        }

        let wanted = TapSession.boundedProcesses(
            newMix.controlledProcessObjects(among: AudioProcesses.all()),
            hasMicrophone: session.hasMicStream
        )
        if wanted == session.requestedProcesses {
            session.publish(parameters, appMix: appMix, micMonitor: micMonitor)
        } else {
            await rebuild()
        }
    }

    /// Compile and publish new settings.
    ///
    /// Cheap enough to call on every frame of a slider drag: the audio thread
    /// picks up the most recent publication and skips any it missed, which is
    /// the right behaviour for parameters. Never blocks either side.
    public func setParameters(_ newParameters: DSPParameters) {
        parameters = newParameters
        publicationCount &+= 1
        session?.publish(newParameters, appMix: appMix, micMonitor: micMonitor)
    }

    private var publicationCount: UInt64 = 0

    // MARK: - Spectrum

    /// Whether the analyzer is running.
    ///
    /// Remembered across sessions here rather than in the session, so that a
    /// device change — which builds a whole new `TapSession` — does not
    /// silently switch the display off.
    private var isSpectrumEnabled = false

    public func setSpectrumEnabled(_ enabled: Bool) {
        isSpectrumEnabled = enabled
        session?.spectrum.isEnabled = enabled
    }

    /// The newest band levels, or nil if nothing has been published since
    /// `sequence`.
    ///
    /// Returning nil rather than a repeat is what lets a caller poll this at
    /// display rate and still only touch its observable state when the
    /// analyzer has actually produced something.
    public func spectrumFrame(after sequence: UInt64) -> SpectrumFrame? {
        session?.spectrum.latestFrame(after: sequence)
    }

    // MARK: - Goniometer

    /// Same "remembered here, not in the session" reasoning as
    /// `isSpectrumEnabled`.
    private var isGoniometerEnabled = false

    /// Frames per snapshot — a little over 10 ms at 48 kHz. Short enough that
    /// a redraw at display rate reads as one continuous shape rather than a
    /// slideshow of disjoint windows, long enough that the shape a signal
    /// actually traces is legible rather than a handful of stray dots.
    public static let goniometerWindow = 512

    public func setGoniometerEnabled(_ enabled: Bool) {
        isGoniometerEnabled = enabled
        session?.goniometerRing.isEnabled = enabled
    }

    /// The most recent `Self.goniometerWindow` stereo pairs, oldest first, or
    /// nil if the ring has not filled yet or the copy was torn — both
    /// handled the same way `SpectrumEngine.tick()` handles them: skip this
    /// poll, the next one is milliseconds away.
    ///
    /// Unlike the spectrum, this is a plain copy rather than a transform, so
    /// it is read directly here rather than through a dedicated queue the way
    /// `SpectrumEngine` reads its ring — a copy this cheap does not earn a
    /// thread of its own.
    public func goniometerSnapshot() -> [GoniometerSample]? {
        session?.goniometerRing.snapshot(count: Self.goniometerWindow)
    }

    /// Read the audio thread's counters. Cheap enough to poll at frame rate.
    public func diagnostics() -> Diagnostics {
        guard let context = session?.context else {
            return Diagnostics(
                framesRendered: 0, buffersRendered: 0, silentBuffers: 0,
                mismatchedBuffers: 0, inputChannelCount: 0, dspFaults: 0,
                peakLeft: 0, peakRight: 0,
                vuLeft: 0, vuRight: 0, correlation: 0, compressorReductionDecibels: 0,
                limiterReductionDecibels: 0, feedbackDuckDecibels: 0,
                publicationCount: publicationCount
            )
        }
        let peaks = context.drainPeaks()
        let vu = context.drainVU()
        let correlation = context.drainCorrelation()
        return Diagnostics(
            framesRendered: context.framesRendered,
            buffersRendered: context.buffersRendered,
            silentBuffers: context.silentBuffers,
            mismatchedBuffers: context.mismatchedBuffers,
            inputChannelCount: context.inputChannelCount,
            dspFaults: context.dspFaults,
            peakLeft: peaks.left,
            peakRight: peaks.right,
            vuLeft: vu.leftAverage,
            vuRight: vu.rightAverage,
            correlation: correlation,
            compressorReductionDecibels: context.compressorReductionDecibels,
            limiterReductionDecibels: context.limiterReductionDecibels,
            feedbackDuckDecibels: context.feedbackDuckDecibels,
            publicationCount: publicationCount
        )
    }
}

import CoreAudio
import Foundation
import RackRealtime

/// The live Core Audio objects behind one capture-and-render path: a process
/// tap, a private aggregate device wrapping the real output, and the IOProc
/// that joins them.
///
/// This is a class rather than a struct so that `deinit` can guarantee
/// teardown. An orphaned aggregate device does not disappear when the process
/// forgets about it — it lingers in the system's device list and turns up in
/// Audio MIDI Setup — so the destruction path must not depend on anyone
/// remembering to call it.
///
/// The construction order and the meaning of each flag are documented in
/// AUDIO.md. Several of them are the difference between working audio and
/// silence, and none are guessable.
final class TapSession {
    let tapObjectID: AudioObjectID

    /// Every tap, in aggregate tap-list order: slot 0 global, then one per
    /// controlled process.
    let allTapObjectIDs: [AudioObjectID]

    /// The process objects that got their own tap, in stream order. Stream
    /// *i + 1* carries process `controlledProcesses[i]`.
    let controlledProcesses: [AudioObjectID]

    /// The bounded tap request, including processes whose tap creation failed.
    /// Comparing edits with the successful subset would rebuild on every fader
    /// move whenever a requested tap failed or exceeded the stream budget.
    let requestedProcesses: [AudioObjectID]

    let aggregateDeviceID: AudioDeviceID
    let context: UnsafeMutablePointer<TapRenderContext>

    let outputDeviceID: AudioObjectID
    let outputDeviceUID: String
    let outputDeviceName: String

    /// The monitored microphone's UID, when one is in the aggregate.
    ///
    /// Its presence is what shifts every other stream along by one — see
    /// `micStreamIndex` and `streamGains(for:micMonitor:)`.
    let micInputDeviceUID: String?

    /// Where the microphone lands in the aggregate's input streams, when it
    /// is present at all.
    ///
    /// **Zero, ahead of the taps** — measured on real hardware rather than
    /// assumed, and the opposite of what the tap-list ordering elsewhere in
    /// this file would suggest. A private aggregate carrying one mic
    /// sub-device and one process tap presents the mic as input stream 0
    /// (mono) and the tap as stream 1 (stereo), even though the mic is
    /// appended to the sub-device list *after* the output device and the tap
    /// list is separate. Core Audio documents none of this, so it is a fact
    /// about observed behaviour, not a guarantee — which is why it is named
    /// here once, rather than spelled `0` at the two places that need it.
    ///
    /// If a future macOS reorders this, the symptom is unmistakable and is
    /// already instrumented: `mismatchedBuffers` climbs on every callback,
    /// because the render path finds a mono buffer where it expected a stereo
    /// one.
    static let micStreamIndex = 0

    /// Whether this session's aggregate actually carries a microphone.
    var hasMicStream: Bool { micInputDeviceUID != nil }

    /// How many applications may be given a tap of their own, given whether a
    /// microphone is also going into the aggregate.
    ///
    /// The budget is `DSPBlock`'s fixed stream storage, and **the microphone
    /// spends one of those slots too**. It is a sub-device rather than a tap,
    /// which is what makes this easy to get wrong — the tap list and the
    /// sub-device list are separate keys — but the aggregate presents it as an
    /// input stream all the same, ahead of every tap (see `micStreamIndex`).
    ///
    /// Reserving only the global tap was an off-by-one that failed in the worst
    /// available way rather than merely losing a fader. Sixteen taps plus a mic
    /// is seventeen streams: `applyStreamGains` silently drops the seventeenth
    /// gain and reports a stream count of sixteen, `rackMixStreams` finds
    /// seventeen input buffers where the block claims sixteen and declines
    /// rather than guessing — correctly — and the plain-copy fallback then
    /// copies input buffer 0, which is *the microphone*. Every application's
    /// audio vanishes and the mic replaces it.
    ///
    /// Pure, and tested without hardware, for the same reason
    /// `DeviceChangeDecision` is: the arithmetic is the whole of the rule.
    static func maximumControlledProcesses(hasMicrophone: Bool) -> Int {
        let reserved = 1 /* the global tap */ + (hasMicrophone ? 1 : 0)
        return max(DSPChain.maximumStreams - reserved, 0)
    }

    static func boundedProcesses(_ processes: [AudioObjectID], hasMicrophone: Bool) -> [AudioObjectID] {
        Array(processes.prefix(maximumControlledProcesses(hasMicrophone: hasMicrophone)))
    }

    /// The tap UUIDs, in aggregate tap-list order, kept because the aggregate
    /// is not built with them — `start()` attaches them once the device is
    /// already cycling. See `attachTaps`.
    private let tapUUIDs: [UUID]

    /// Mutable, because a device can change its rate underneath a running
    /// stream. Every coefficient depends on it.
    private(set) var sampleRate: Double

    let outputChannelCount: Int

    /// Owns the three parameter slots and publishes into them.
    let parameters = ParameterPublisher()

    /// The analyzer's half of the path: the ring the IOProc drops samples into
    /// and the thread that transforms them.
    ///
    /// Owned here, at the same lifetime as the render context, because the
    /// ordering that makes it safe is the same ordering: the device is stopped
    /// and the analyzer is shut down before either is freed. Splitting the two
    /// across different owners is how that gets broken later.
    let spectrumRing: SpectrumRing
    let spectrum: SpectrumEngine

    /// The goniometer's half of the path: a ring of raw stereo pairs, read
    /// directly rather than through a transform engine of its own — unlike
    /// the spectrum, there is no FFT here, just a copy, and a copy this cheap
    /// does not earn a dedicated queue. `SystemAudioTap.goniometerSnapshot`
    /// reads it straight from whatever thread polls it.
    let goniometerRing: GoniometerRing

    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private var isTornDown = false

    // MARK: - Construction

    /// Build the whole path, unwinding cleanly if any step fails.
    ///
    /// Partial construction is the dangerous case: a tap created but no
    /// aggregate to consume it still mutes the processes it taps, so a failure
    /// halfway through would leave the Mac silent until reboot. Every failure
    /// path below destroys what it already made.
    ///
    /// - Parameter controlling: process objects to give their own tap, and so
    ///   their own gain. They are excluded from the global tap, which carries
    ///   everything else. An empty list produces exactly the single-tap
    ///   configuration Phases 1–3 used.
    /// - Parameter micInputDevice: a microphone to fold into the aggregate
    ///   for live monitoring, or nil for the output-only configuration every
    ///   phase before this one used.
    static func create(
        controlling controlled: [AudioObjectID] = [],
        micInputDevice: AudioObjectID? = nil
    ) throws -> TapSession {
        try build(controlling: controlled, micInputDevice: micInputDevice)
    }

    private static func build(
        controlling controlled: [AudioObjectID],
        micInputDevice: AudioObjectID?
    ) throws -> TapSession {
        let outputDevice = try AudioDevices.defaultOutputDevice()
        let outputUID = try AudioDevices.uid(of: outputDevice)
        let outputName = try AudioDevices.name(of: outputDevice)
        let sampleRate = try AudioDevices.nominalSampleRate(of: outputDevice)
        let outputChannels = try AudioDevices.outputChannelCount(of: outputDevice)
        // Resolved before anything is built, so a bad mic UID fails loudly
        // rather than after taps and an aggregate have already been created.
        let micUID = try micInputDevice.map { try AudioDevices.uid(of: $0) }

        // Slot 0 is always the global tap; the rest follow in the order given,
        // and that order is what the render path uses to match a stream to an
        // application. It must not be rearranged.
        let controlled = boundedProcesses(controlled, hasMicrophone: micUID != nil)

        var tapObjectIDs: [AudioObjectID] = []

        func destroyTaps() {
            for tap in tapObjectIDs { AudioHardwareDestroyProcessTap(tap) }
        }

        // Per-application taps first, and each one allowed to fail on its own.
        //
        // A per-process tap fails for reasons that are nobody's fault: the
        // process exited between being listed and being tapped, or it spawns
        // helpers and the mapping was never one to one. This used to abort the
        // whole build and retry with *no* per-app taps at all, so one departing
        // app silently took away every other app's fader.
        //
        // The order matters and is the reason this moved above the global tap:
        // the global tap must exclude exactly the applications that got a tap
        // of their own. Excluding one that then failed would leave it out of
        // both taps, and an application in neither tap is an application nobody
        // can hear.
        var appUUIDs: [UUID] = []
        var succeeded: [AudioObjectID] = []
        for process in controlled {
            let uuid = UUID()
            guard let tap = try? createAppTap(uuid: uuid, process: process) else {
                continue
            }
            appUUIDs.append(uuid)
            tapObjectIDs.append(tap)
            succeeded.append(process)
        }

        let globalUUID = UUID()
        let tapUUIDs = [globalUUID] + appUUIDs

        do {
            // Slot 0 is always the global tap, whatever order it was built in.
            tapObjectIDs.insert(
                try createGlobalTap(uuid: globalUUID, excluding: succeeded),
                at: 0
            )
        } catch {
            destroyTaps()
            throw error
        }

        let aggregateID: AudioDeviceID
        do {
            aggregateID = try createAggregateDevice(
                outputDeviceUID: outputUID,
                micInputDeviceUID: micUID
            )
        } catch {
            destroyTaps()
            throw error
        }

        let tapObjectID = tapObjectIDs[0]

        do {
            let aggregateOutputChannels =
                (try? AudioDevices.outputChannelCount(of: aggregateID)) ?? outputChannels

            return TapSession(
                tapObjectID: tapObjectID,
                allTapObjectIDs: tapObjectIDs,
                tapUUIDs: tapUUIDs,
                // What actually got a tap, not what was asked for. The
                // difference is what the applications panel marks as
                // global-only.
                controlledProcesses: succeeded,
                requestedProcesses: controlled,
                aggregateDeviceID: aggregateID,
                outputDeviceID: outputDevice,
                outputDeviceUID: outputUID,
                outputDeviceName: outputName,
                micInputDeviceUID: micUID,
                sampleRate: sampleRate,
                outputChannelCount: aggregateOutputChannels
            )
        }
    }

    private init(
        tapObjectID: AudioObjectID,
        allTapObjectIDs: [AudioObjectID],
        tapUUIDs: [UUID],
        controlledProcesses: [AudioObjectID],
        requestedProcesses: [AudioObjectID],
        aggregateDeviceID: AudioDeviceID,
        outputDeviceID: AudioObjectID,
        outputDeviceUID: String,
        outputDeviceName: String,
        micInputDeviceUID: String?,
        sampleRate: Double,
        outputChannelCount: Int
    ) {
        self.tapObjectID = tapObjectID
        self.allTapObjectIDs = allTapObjectIDs
        self.tapUUIDs = tapUUIDs
        self.controlledProcesses = controlledProcesses
        self.requestedProcesses = requestedProcesses
        self.aggregateDeviceID = aggregateDeviceID
        self.outputDeviceID = outputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.micInputDeviceUID = micInputDeviceUID
        self.sampleRate = sampleRate
        self.outputChannelCount = outputChannelCount

        // Built from locals rather than from `self`, so both can be `let`.
        let ring = SpectrumRing()
        self.spectrumRing = ring
        self.spectrum = SpectrumEngine(ring: ring, sampleRate: sampleRate)
        self.goniometerRing = GoniometerRing()

        // One allocation, at a stable address, for the life of the session.
        // The IOProc holds this pointer; it must outlive every callback, which
        // is why it is freed only in tearDown() after AudioDeviceStop.
        self.context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        self.context.initialize(to: TapRenderContext())

        // Point the audio thread at the parameter exchange, and match the
        // gain smoothing to the device's rate before anything renders.
        self.context.pointee.exchange = parameters.exchange
        self.context.pointee.slots = parameters.slots
        self.context.pointee.sampleRate = sampleRate
        self.context.pointee.dsp.smoothingCoefficient =
            DSPRenderState.smoothingCoefficient(forSampleRate: sampleRate)
        self.context.pointee.reverbSend.crossfadeCoefficient =
            Reverb.crossfadeCoefficient(forSampleRate: sampleRate)
        self.context.pointee.delaySend.crossfadeCoefficient =
            Delay.crossfadeCoefficient(forSampleRate: sampleRate)

        // Pointed at the ring, but with its enable flag still down: until
        // something asks for a spectrum the IOProc's only extra work is one
        // relaxed load per buffer.
        self.context.pointee.spectrum = spectrumRing.header
        self.context.pointee.goniometer = goniometerRing.header
    }

    /// The tap description. Each flag here is load-bearing:
    ///
    /// - excluding our own process stops the feedback loop: we render *to* a
    ///   device, and a global tap would otherwise capture that render;
    /// - `isPrivate` keeps the tap out of other applications' device lists;
    /// - `mutedWhenTapped` stops the original signal reaching the speakers
    ///   alongside our processed render, which would otherwise double.
    private static func createGlobalTap(
        uuid: UUID,
        excluding controlled: [AudioObjectID]
    ) throws -> AudioObjectID {
        // The header spells this parameter processesObjectIDsToExcludeFromTap:
        // it holds audio object IDs, not PIDs. A raw PID is accepted and
        // silently excludes nothing, which presents as a feedback loop.
        var excluded: [AudioObjectID] = controlled
        if let ourProcessObject = AudioDevices.processObject(for: getpid()) {
            excluded.append(ourProcessObject)
        }

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excluded
        )
        description.uuid = uuid
        description.name = "Rack System Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        return try instantiate(description, context: "creating the global system tap")
    }

    /// A tap carrying one application's audio and nothing else.
    ///
    /// `mutedWhenTapped` again: the process's own output must not also reach
    /// the speakers, or its audio arrives twice — once at its own level and
    /// once at the level we chose for it.
    private static func createAppTap(
        uuid: UUID,
        process: AudioObjectID
    ) throws -> AudioObjectID {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = uuid
        description.name = "Rack App Tap \(process)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return try instantiate(description, context: "creating a per-application tap")
    }

    private static func instantiate(
        _ description: CATapDescription,
        context: String
    ) throws -> AudioObjectID {
        var tapObjectID = AudioObjectID(kAudioObjectUnknown)
        // The first call raises the TCC prompt, and only for a signed binary.
        try AudioHardwareCreateProcessTap(description, &tapObjectID)
            .orThrow("AudioHardwareCreateProcessTap", context)

        guard tapObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(
                operation: "AudioHardwareCreateProcessTap",
                status: kAudioHardwareBadObjectError,
                context: "\(context) — returned no object"
            )
        }
        return tapObjectID
    }

    /// A private aggregate device whose main sub-device is the real output.
    /// Rendering to this aggregate is what puts our processing in the path.
    ///
    /// **Built without its taps**, which is not an oversight — see
    /// `attachTaps`. They are added by `start()`, once the device is already
    /// running.
    ///
    /// `micInputDeviceUID`, when present, adds the mic-monitor spike's device
    /// as a *second* sub-device rather than a tap — it is real hardware, not
    /// a process to capture from. Drift-compensated
    /// (`kAudioSubDeviceDriftCompensationKey`): the main sub-device drives the
    /// aggregate's clock, and anything else in the aggregate needs its own
    /// clock reconciled against it or the two slowly walk apart.
    private static func createAggregateDevice(
        outputDeviceUID: String,
        micInputDeviceUID: String?
    ) throws -> AudioDeviceID {
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
        if let micInputDeviceUID {
            subDevices.append([
                kAudioSubDeviceUIDKey: micInputDeviceUID,
                kAudioSubDeviceDriftCompensationKey: true
            ])
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rack Output",
            kAudioAggregateDeviceUIDKey:
                "\(AudioDevices.rackAggregateUIDPrefix)\(UUID().uuidString)",
            // The real output device drives the clock. Getting this wrong
            // means drift compensation fights the hardware.
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            // Private: does not appear in Sound settings or other apps.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Without this the tap exists but never delivers.
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices
        ]

        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        try AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateID
        )
        .orThrow(
            "AudioHardwareCreateAggregateDevice",
            "building the private aggregate around \(outputDeviceUID)"
        )

        guard aggregateID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CoreAudioError(
                operation: "AudioHardwareCreateAggregateDevice",
                status: kAudioHardwareBadDeviceError,
                context: "building the private aggregate — returned no device"
            )
        }
        return aggregateID
    }

    // MARK: - Running

    /// Install the IOProc and start the device.
    ///
    /// Deliberately not AVAudioEngine: setting
    /// `kAudioOutputUnitProperty_CurrentDevice` on a tap-backed aggregate
    /// returns noErr and then silently keeps reading the default input. See
    /// AUDIO.md.
    func start() throws {
        guard !isRunning, !isTornDown else { return }

        let context = self.context
        var procID: AudioDeviceIOProcID?

        try AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            nil  // nil queue: run on the device's own realtime thread
        ) { _, inputData, _, outputData, _ in
            rackRender(
                context: context,
                input: inputData,
                output: outputData
            )
        }
        .orThrow(
            "AudioDeviceCreateIOProcIDWithBlock",
            "installing the render callback on the aggregate"
        )

        guard let procID else {
            throw CoreAudioError(
                operation: "AudioDeviceCreateIOProcIDWithBlock",
                status: kAudioHardwareUnspecifiedError,
                context: "installing the render callback — returned no proc ID"
            )
        }
        ioProcID = procID

        do {
            try AudioDeviceStart(aggregateDeviceID, procID)
                .orThrow("AudioDeviceStart", "starting the aggregate device")
            // Only now, with the device already cycling. If this fails the
            // aggregate is running with nothing to capture, which is silence
            // rather than a degraded sound — so it takes the whole session
            // down rather than being logged and shrugged at.
            try attachTaps()
        } catch {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
            throw error
        }

        isRunning = true
    }

    /// Put the taps into the running aggregate.
    ///
    /// **The reason Rack did nothing until something else played.** A private
    /// aggregate that is *created* carrying a tap does not begin its IO cycle
    /// until one of the tapped processes actually produces audio: the engine
    /// reported `running`, `AudioDeviceStart` returned `noErr`, and the IOProc
    /// was never called once — `buffersRendered` sat at zero indefinitely. The
    /// first sound played after that arrived at a device still spinning up,
    /// while `mutedWhenTapped` had already muted its source, so the front of it
    /// was swallowed; everything after was fine, which is exactly the shape of
    /// "it only works once you have let some audio through it".
    ///
    /// Measured rather than reasoned about. Four configurations, counting
    /// IOProc callbacks over two seconds with nothing playing:
    ///
    /// | | callbacks |
    /// |---|---|
    /// | private, tap in the creation description | **0** |
    /// | private, no drift compensation on the tap | **0** |
    /// | not private, tap in the creation description | 188 |
    /// | private, tap auto-start off | 188 |
    ///
    /// Neither of the two that work is usable on its own: a non-private
    /// aggregate turns up in Sound settings and in every other application's
    /// device list, and can be selected as the output, which routes Rack into
    /// itself; and with auto-start off the tap delivers permanent silence,
    /// which is the failure `kAudioAggregateDeviceTapAutoStartKey` exists to
    /// prevent. Attaching afterwards is the third door: the aggregate is
    /// created bare — where it cycles from the moment it starts, like any
    /// ordinary device — and the taps go in through
    /// `kAudioAggregateDevicePropertyTapList` once it is running.
    ///
    /// **The property takes UID strings, not the per-tap dictionaries** the
    /// creation description uses. Handing it dictionaries returns `noErr` and
    /// leaves the tap list empty, which would be silence again. Nothing is lost
    /// by the plainer form: `kAudioAggregateDevicePropertyComposition` reports
    /// `{ uid = … }` and nothing else for a tap declared at creation *with*
    /// `kAudioSubTapDriftCompensationKey`, so the flag is not part of what the
    /// aggregate remembers either way.
    ///
    /// Order is preserved, and load-bearing for the same reason it always was:
    /// the aggregate presents its taps as input streams in this order, and the
    /// render path matches a stream to an application by position.
    private func attachTaps() throws {
        guard !tapUUIDs.isEmpty else { return }

        var address = AudioProperty.address(kAudioAggregateDevicePropertyTapList)
        var list = tapUUIDs.map(\.uuidString) as CFArray
        try withUnsafeMutablePointer(to: &list) { pointer in
            AudioObjectSetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFArray>.size),
                pointer
            )
        }
        .orThrow(
            "AudioObjectSetPropertyData",
            "attaching \(tapUUIDs.count) tap(s) to the running aggregate"
        )
    }

    /// Compile and publish new parameters. Never blocks the audio thread.
    ///
    /// `appMix` is resolved against this session's tap order here, because the
    /// mapping from application to stream is a property of how the aggregate
    /// was built and nothing above needs to know it.
    /// Every argument is required, deliberately — none of them defaults.
    ///
    /// A publication is the *whole* mix, not a patch to it: whatever is not
    /// passed here is not merely left alone, it is overwritten with the
    /// default. `micMonitor` defaulting to `MicMonitor()` meant a caller who
    /// forgot it published "microphone off" — and since every knob movement
    /// publishes, moving any unrelated control silently muted the
    /// microphone until something touched the Input panel and republished the
    /// real value. That was a real bug, and the defaults were what allowed a
    /// missing argument to compile.
    func publish(
        _ newParameters: DSPParameters,
        appMix: AppMix,
        micMonitor: MicMonitor
    ) {
        parameters.publish(
            newParameters,
            streamGains: streamGains(for: appMix, micMonitor: micMonitor),
            // Compiled here rather than by the caller because it needs both
            // halves of the question: whether the user wants the guard, and
            // whether this session actually carries a microphone for it to
            // watch. Only this object knows the second.
            feedback: FeedbackCoefficients.compile(
                isEnabled: micMonitor.isFeedbackGuardEnabled,
                micStreamIndex: hasMicStream ? Self.micStreamIndex : nil,
                sampleRate: sampleRate
            ),
            sampleRate: sampleRate
        )
    }

    /// Gain per input stream, in the order the aggregate actually presents
    /// them: the microphone first when one is present (see `micStreamIndex`),
    /// then the global tap, then one per controlled process.
    ///
    /// Ordering here is load-bearing in the same way the tap list is — the
    /// render path matches a stream to a source by position, so getting this
    /// wrong applies the microphone's gain to the system audio and vice
    /// versa. It is built from `hasMicStream` rather than from whether the
    /// monitor is *audible*, because a muted microphone still occupies a
    /// stream; it simply occupies it at a gain of zero.
    ///
    /// An empty result means "one stream at unity" — the single-tap
    /// configuration the earliest phases proved, and the only case that still
    /// takes the plain-copy path in `rackRender`.
    func streamGains(for appMix: AppMix, micMonitor: MicMonitor) -> [Float] {
        guard hasMicStream || !controlledProcesses.isEmpty else { return [] }

        var gains: [Float] = []
        if hasMicStream {
            gains.append(Float(micMonitor.gain))
        }
        // The global tap, always at unity: per-application level is applied
        // to the individual taps below, and the master fader is a later
        // stage of the chain entirely.
        gains.append(1)
        for process in controlledProcesses {
            gains.append(Float(appMix.gain(forProcessObject: process)))
        }
        return gains
    }

    /// Adopt a new sample rate without rebuilding anything.
    ///
    /// A rate change makes every coefficient wrong — they are designed against
    /// a specific rate — but the tap, the aggregate and the IOProc are all
    /// still valid, so recompiling is enough and costs a fraction of a rebuild.
    ///
    /// The running state is cleared as well. It holds samples from a stream at
    /// the old rate, and feeding those into filters designed for the new one
    /// is a burst of noise at exactly the moment the user is listening for a
    /// glitch. *Asked for* rather than done here — see
    /// `TapRenderContext.resetRequested`: this runs on the actor handling
    /// device notifications, and that state belongs to the audio thread.
    func retune(
        to newSampleRate: Double,
        parameters newParameters: DSPParameters,
        appMix: AppMix,
        micMonitor: MicMonitor
    ) {
        guard newSampleRate.isFinite, newSampleRate > 0 else { return }
        sampleRate = newSampleRate
        // The published block carries the rate and smoothing coefficients.
        // The IOProc adopts them and clears old-rate state in the same buffer.
        // The analyzer maps bins to frequencies by the rate. Left stale, every
        // band on the display would be labelled with the wrong pitch.
        spectrum.retune(to: newSampleRate)
        publish(newParameters, appMix: appMix, micMonitor: micMonitor)
    }

    // MARK: - Teardown

    /// Reverse of construction, and safe to call more than once.
    ///
    /// Order matters: stop before destroying the IOProc, destroy the IOProc
    /// before the device, and free the render context last — the audio thread
    /// dereferences it until AudioDeviceStop returns.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true

        // First, and before anything else is released. `stop()` waits for any
        // transform already running, so from here on nothing but the audio
        // thread is looking at the ring — and that ends two statements later.
        spectrum.stop()

        if let ioProcID {
            if isRunning {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                isRunning = false
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        // Destroying the tap is what un-mutes the tapped processes. If this is
        // ever skipped the Mac stays silent, so it must not be conditional on
        // anything above having succeeded.
        for tap in allTapObjectIDs where tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }

        // The context's own memory is about to be freed, which does nothing
        // about the separately-allocated line buffers a pointer inside it
        // owns — the reverb's four per channel and the echo's one per
        // channel — those have to be released by hand, and before the
        // struct holding the pointers to them is gone.
        context.pointee.reverb.free()
        context.pointee.delay.free()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    deinit {
        tearDown()
    }
}

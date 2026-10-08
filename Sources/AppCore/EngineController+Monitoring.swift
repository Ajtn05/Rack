import AudioCore
import Foundation
import os

/// Engine lifecycle: start/stop/toggle, the state-change observer, the poll
/// loop, the standby state machine, and folding diagnostics into the meters.
///
/// The most tightly coupled part of the controller — nearly every function
/// here touches `tap` and the poll/standby state together — so unlike
/// `EngineController+Shell.swift` this is not a low-coupling extraction, just
/// a large, coherent one: "what happens while the engine is running" is one
/// concern, even though it is not a small one.
extension EngineController {
    /// Meters need to be sampled at something like display rate. At 10 Hz the
    /// bar shows the maximum of each 100 ms window and steps between them,
    /// which reads as lag however good the ballistics are.
    ///
    /// Thirty rather than sixty: each tick is a cross-actor round trip to
    /// `tap.diagnostics()` plus an `@Observable` mutation that walks every view
    /// reading a meter, and doing that sixty times a second was measurable
    /// idle energy for a difference nothing downstream could show — the
    /// ballistics in `PeakMeter` and `SpectrumBallistics` already smooth
    /// between samples, so halving the sample rate halves the CPU work behind
    /// a display that looks the same.
    private static let pollInterval = Duration.milliseconds(33)

    /// How long since the last control change before the display goes to
    /// standby and monitoring stops entirely — see `enterDisplayIdle`.
    private static let idleThreshold = Duration.seconds(20)

    /// How often the process list, the device list, and the heartbeat log line
    /// are refreshed.
    ///
    /// Slower than the meter poll on purpose: enumerating every audio process
    /// and every audio device is a real handful of Core Audio calls each, not
    /// the relaxed atomic loads a meter tick costs, and nothing downstream
    /// needs it fresher than "a newly launched app shows up within a few
    /// seconds." Five rather than two roughly halves that cost for a change no
    /// one can see happen.
    private static let heartbeatInterval: Double = 5

    // MARK: - Control

    /// Start capturing. The first call on a machine raises the system's
    /// audio-capture permission prompt.
    ///
    /// The settings are handed over *before* the path is built, in the same
    /// actor call, and that ordering is the whole of it. Everything restored
    /// from the last session lives here, on the controller; the actor keeps
    /// its own copy and builds each session from that copy. Nothing used to
    /// carry the parameters or the app mix across, so a freshly started engine
    /// rendered `.flat` while every knob on screen showed the user's saved
    /// sound — Rack looked switched on and did nothing until some control was
    /// moved, which is the one action that had always published. See
    /// `SystemAudioTap.adopt`.
    public func start() {
        errorDetail = nil
        setPoweredOn(true)
        Task { [tap, parameters, appMix, micMonitor] in
            await tap.adopt(
                parameters: parameters, appMix: appMix, micMonitor: micMonitor
            )
            do {
                try await tap.start()
            } catch {
                // The state stream already carries the failure; this catch
                // stops it being an unhandled error.
                _ = error
            }
        }
    }

    public func stop() {
        setPoweredOn(false)
        Task { [tap] in await tap.stop() }
    }

    public func toggle() {
        status.isRunning ? stop() : start()
    }

    // MARK: - Observation

    func observeStateChanges() {
        stateTask = Task { [weak self, tap] in
            // This Task inherits main-actor isolation from `observeStateChanges`,
            // so `apply` needs no hop.
            for await state in tap.stateChanges {
                guard let self else { return }
                self.apply(state)
            }
        }
    }

    private func apply(_ state: SystemAudioTap.State) {
        switch state {
        case .idle:
            status = .idle
            stopPolling()
            clearMeters()
        case .starting:
            status = .starting
            startingAt = ContinuousClock.now
            Self.log.notice("engine starting")
        case .running(let info):
            status = .running
            if let startingAt {
                readout.lastStartMilliseconds =
                    (ContinuousClock.now - startingAt).seconds * 1000
                self.startingAt = nil
            }
            Self.log.notice(
                """
                engine running — device \(info.outputDeviceName, privacy: .public) \
                (\(info.outputDeviceUID, privacy: .public)) \
                \(info.sampleRate, privacy: .public) Hz \
                → \(info.outputChannelCount, privacy: .public) out \
                — up in \(self.readout.lastStartMilliseconds, privacy: .public) ms
                """
            )
            readout.deviceName = info.outputDeviceName
            readout.outputDeviceUID = info.outputDeviceUID
            readout.sampleRate = info.sampleRate
            readout.outputChannelCount = info.outputChannelCount
            // The filters are designed for a rate, so the curve is only true
            // at that rate. A device change is where it moves.
            refreshResponseCurve()
            // The device may have changed under us — that is most of what a
            // .running transition means after the first one — so this is the
            // moment to reconsider which preset applies.
            evaluateAutoSwitch()
            startPolling()
            Task { [weak self, tap] in
                let snapshot = await tap.deviceSnapshot()
                guard let self else { return }
                self.audioProcesses = snapshot.audioProcesses
                self.outputDevices = snapshot.outputDevices
                self.inputDevices = snapshot.inputDevices
                self.controlledApplicationIDs = snapshot.controlledApplicationIDs
                self.isMicHeldForFeedback = snapshot.isMicHeldForFeedback
            }
        case .stopped:
            status = .stopped
            Self.log.notice("engine stopped")
            stopPolling()
            clearMeters()
        case .failed(let error):
            status = .failed(error.symbolicName ?? error.fourCharCode ?? "\(error.status)")
            errorDetail = error.description
            Self.log.error("engine failed — \(error.description, privacy: .public)")
            stopPolling()
            clearMeters()
        }
    }

    /// Put the meters back to silence.
    ///
    /// Every path out of `.running` ends here. Only `.stopped` used to, so an
    /// engine that failed — or one that went back to idle — left the bars and
    /// the peak reading frozen at whatever had last been playing, which is the
    /// one moment a stale number is most likely to be believed.
    private func clearMeters() {
        meterLeft.reset()
        meterRight.reset()
        vuLeft.reset()
        vuRight.reset()
        correlation.reset()
        // Peaks to silence, and the gain-reduction needles to their baseline
        // (no reduction) rather than frozen at the last reading — the same
        // reason the ballistic meters above reset. This is what a needle shows
        // in standby: its resting position, not wherever it happened to be when
        // the poll stopped.
        levels = EngineLevels()
        // For the same reason: a spectrum left on screen after the engine goes
        // away is a picture of audio that stopped.
        clearSpectrum()
        clearGoniometer()
    }

    /// Logged rather than printed so that a build running outside a terminal —
    /// which is every build, once this is a menu bar app — is still
    /// diagnosable:
    ///
    ///     log stream --predicate 'subsystem == "dev.rack.Rack"'
    static let log = Logger(subsystem: "dev.rack.Rack", category: "engine")

    private func startPolling() {
        guard pollTask == nil else { return }
        // Powering on is itself an interaction — an amplifier that has sat
        // switched off for an hour should not wake up already asleep — and
        // this is also the one place that undoes a standby: the flag is
        // cleared and the analyzer's capture re-armed for the current mode, so
        // a wake from any path (an interaction, or a device rebuild that
        // arrives while idle) ends up in the same running state.
        isDisplayIdle = false
        lastInteractionAt = ContinuousClock.now
        applyAnalyzerMode()
        pollTask = Task { [weak self, tap] in
            var lastTick = ContinuousClock.now
            var secondsSinceLog = 0.0

            while !Task.isCancelled {
                // Standby is checked before any work, so an untouched unit
                // never does a round of monitoring just to decide it should
                // have been asleep. Idle now ends the loop outright rather than
                // slowing it — the display draws a placeholder and nothing here
                // runs again until an interaction restarts polling.
                if let self, self.isIdleTimeoutEnabled,
                   (ContinuousClock.now - self.lastInteractionAt) > Self.idleThreshold {
                    self.enterDisplayIdle()
                    return
                }

                let diagnostics = await tap.diagnostics()
                // `!Task.isCancelled` as well as a live self: a manual standby
                // (`forceDisplayIdle`) cancels this task and rests the meters
                // in the same main-actor turn, so a tick that was mid-await
                // must not then apply a diagnostics reading over that baseline.
                guard let self, !Task.isCancelled else { return }

                // Measured rather than assumed: Task.sleep guarantees a floor,
                // not a period, and the decay is wrong if we pretend otherwise.
                let now = ContinuousClock.now
                let elapsed = (now - lastTick).seconds
                lastTick = now

                self.apply(diagnostics, elapsed: elapsed)
                // Independent of each other — neither reads what the other
                // writes — so there is no reason to await them in sequence.
                async let spectrumDrained: Void = self.drainSpectrum(tap: tap, now: now)
                async let goniometerDrained: Void = self.drainGoniometer(tap: tap)
                _ = await (spectrumDrained, goniometerDrained)
                guard !Task.isCancelled else { return }

                // A heartbeat every `heartbeatInterval`, so "is audio actually
                // flowing?" is answerable from the log without a window open.
                // The process list is refreshed on the same beat: enumerating
                // it is a Core Audio round trip per process, which has no
                // business happening at meter rate.
                secondsSinceLog += elapsed
                if secondsSinceLog >= Self.heartbeatInterval {
                    secondsSinceLog = 0
                    // The plumbing counters ride this beat rather than the
                    // meter one — see `apply(_:elapsed:)`. They climb on every
                    // buffer, so refreshing them thirty times a second kept
                    // `readout` changing thirty times a second no matter what
                    // the audio was doing, and dragged every view reading a
                    // device name or a sample rate into redrawing with it.
                    self.applyCounters(diagnostics)
                    let snapshot = await tap.deviceSnapshot()
                    guard !Task.isCancelled else { return }
                    self.audioProcesses = snapshot.audioProcesses
                    self.outputDevices = snapshot.outputDevices
                    self.inputDevices = snapshot.inputDevices
                    self.controlledApplicationIDs = snapshot.controlledApplicationIDs
                    self.isMicHeldForFeedback = snapshot.isMicHeldForFeedback
                    Self.log.info(
                        """
                        frames=\(diagnostics.framesRendered, privacy: .public) \
                        ioprocs=\(diagnostics.buffersRendered, privacy: .public) \
                        silent=\(diagnostics.silentBuffers, privacy: .public) \
                        mismatched=\(diagnostics.mismatchedBuffers, privacy: .public) \
                        in=\(diagnostics.inputChannelCount, privacy: .public)ch \
                        peakL=\(diagnostics.peakLeft, privacy: .public) \
                        peakR=\(diagnostics.peakRight, privacy: .public)
                        """
                    )
                }

                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        // Standby describes a running amplifier nobody is touching, not a
        // stopped one — the display goes dark for its own reason, not this
        // one.
        isDisplayIdle = false
    }

    /// Put the display to standby: end the poll loop and take the analyzer's
    /// capture out of the IOProc, so an untouched unit costs nothing to
    /// monitor. The always-on peak/VU/correlation accumulators stay running —
    /// they are one add per sample and are what let a wake be instant — but the
    /// spectrum and goniometer captures, which are real IOProc work plus a
    /// whole analysis thread, are switched off. The audio keeps flowing; only
    /// the looking at it stops. Called from inside the poll loop, which returns
    /// immediately after.
    private func enterDisplayIdle() {
        guard !isDisplayIdle else { return }
        isDisplayIdle = true
        pollTask = nil
        Task { [tap] in
            await tap.setSpectrumEnabled(false)
            await tap.setGoniometerEnabled(false)
        }
        // Rest the on-screen meters so nothing is frozen mid-swing behind the
        // standby placeholder.
        clearMeters()
    }

    /// Wake the display from standby. Discards whatever the always-on meters
    /// accumulated unseen while idle — a peak up to `idleThreshold` old is
    /// stale, not live — and *then* resumes polling, so the first tick reads
    /// only post-wake levels. `startPolling` clears the flag and re-arms
    /// capture. A no-op if the display was not actually idle.
    func exitDisplayIdle() {
        guard isDisplayIdle else { return }
        isDisplayIdle = false
        Task { [weak self, tap] in
            _ = await tap.diagnostics()
            guard let self, self.status.isRunning, !self.isDisplayIdle else { return }
            self.startPolling()
        }
    }

    /// Send the display to standby by hand, without waiting out `idleThreshold`
    /// — the manual equivalent of the automatic trip, and independent of
    /// whether the automatic one is even enabled. Only meaningful while the
    /// engine is running and not already asleep; a no-op otherwise. Any
    /// interaction wakes it again, exactly as an automatic idle does. Cancels
    /// the poll loop rather than letting it notice on its own, so the standby
    /// is immediate; the loop's `!Task.isCancelled` guard keeps a tick already
    /// in flight from writing over the rested meters.
    public func forceDisplayIdle() {
        guard status.isRunning, !isDisplayIdle else { return }
        pollTask?.cancel()
        enterDisplayIdle()
    }

    /// Flip the display between standby and awake — what the Standby button
    /// calls. Off the front of an amplifier this is one button that both parks
    /// the meters and brings them back.
    public func toggleDisplayIdle() {
        if isDisplayIdle {
            exitDisplayIdle()
        } else {
            forceDisplayIdle()
        }
    }

    /// Take a spectrum frame if there is a new one, and advance the ballistics.
    ///
    /// This is the coalescing point. The poll runs at display rate; the
    /// analyzer publishes at thirty a second. Asking for anything *newer than*
    /// the last sequence seen means the majority of polls find nothing, touch
    /// no observable state, and redraw nothing — rather than reassigning an
    /// identical array sixty times a second and inviting SwiftUI to rebuild the
    /// panel each time.
    ///
    /// The ballistics are advanced by the gap between frames rather than by the
    /// poll interval, so the decay is right whatever rate either side runs at.
    private func drainSpectrum(tap: SystemAudioTap, now: ContinuousClock.Instant) async {
        guard analyzerMode.needsSpectrumCapture else { return }
        guard let frame = await tap.spectrumFrame(after: lastSpectrumSequence) else {
            return
        }
        guard !Task.isCancelled, status.isRunning, !isDisplayIdle,
              analyzerMode.needsSpectrumCapture else { return }

        let elapsed = lastSpectrumTick.map { (now - $0).seconds } ?? 0
        lastSpectrumTick = now
        lastSpectrumSequence = frame.sequence
        let clampedElapsed = min(max(elapsed, 0), 1)
        spectrumBallistics.update(
            bandsDecibels: frame.bandsDecibels,
            elapsed: clampedElapsed
        )
        beatMeter.update(
            bassDecibels: BeatMeter.bassLevel(
                bandsDecibels: frame.bandsDecibels,
                bandFrequencies: Self.bandFrequencies(count: frame.bandsDecibels.count)
            ),
            elapsed: clampedElapsed
        )
    }

    /// The band centres for a frame of `count` bands.
    ///
    /// The same geometric series `SpectrumAnalyzer.bandFrequencies` is built
    /// from, restated here from the public `FrequencyResponse` API —
    /// `SpectrumAnalyzer` itself is AudioCore-internal, the FFT machinery's
    /// own concern, not a type this layer is meant to name.
    ///
    /// Memoised on the count, because the analyzer publishes thirty frames a
    /// second and every one of them has the same band count as the last. Built
    /// fresh each time, this was 31 `pow` calls and an array allocation thirty
    /// times a second to produce a constant. The cache is one entry deep: the
    /// count only ever changes if the analyzer is reconfigured, which nothing
    /// currently does at runtime.
    private static var cachedBandFrequencies: (count: Int, values: [Double]) = (0, [])

    private static func bandFrequencies(count: Int) -> [Double] {
        if cachedBandFrequencies.count == count { return cachedBandFrequencies.values }
        let values = FrequencyResponse.logSpacedFrequencies(count: count)
        cachedBandFrequencies = (count, values)
        return values
    }

    /// Take a fresh window of raw stereo pairs, if the goniometer is what is
    /// selected.
    ///
    /// No sequence number to compare against, unlike `drainSpectrum` — there
    /// is no background producer publishing discrete frames here, just a
    /// ring that is always a little further along each time it is asked, so
    /// every poll's snapshot is by construction newer than the last.
    private func drainGoniometer(tap: SystemAudioTap) async {
        guard analyzerMode.needsGoniometerCapture else { return }
        guard let samples = await tap.goniometerSnapshot() else { return }
        guard !Task.isCancelled, status.isRunning, !isDisplayIdle,
              analyzerMode.needsGoniometerCapture else { return }
        goniometerSamples = samples
    }

    /// Fold one poll's diagnostics into the meters.
    ///
    /// Every assignment here is guarded by an equality test, and that is not
    /// belt-and-braces. `@Observable` fires its observers on *assignment*, not
    /// on change, so writing a value equal to the one already there still
    /// invalidates every view reading it. Assigning the same settled peak
    /// thirty times a second is a redraw of the whole analyzer thirty times a
    /// second for a picture nobody could tell from the last one — which is
    /// exactly what a paused or silent system used to cost.
    ///
    /// The plumbing counters are deliberately not here: they climb on every
    /// single buffer, so refreshing them at meter rate meant `readout` changed
    /// at meter rate *by construction*, whatever the audio was doing. They are
    /// diagnostics, they are read at a glance, and `pollHeartbeat` refreshes
    /// them on its own much slower beat.
    private func apply(_ diagnostics: SystemAudioTap.Diagnostics, elapsed: Double) {
        let newLevels = EngineLevels(
            peakLeft: diagnostics.peakLeft,
            peakRight: diagnostics.peakRight,
            compressorReductionDecibels: diagnostics.compressorReductionDecibels,
            limiterReductionDecibels: diagnostics.limiterReductionDecibels,
            feedbackDuckDecibels: diagnostics.feedbackDuckDecibels
        )
        if newLevels != levels { levels = newLevels }

        // Advanced in a local and written back only if the ballistic actually
        // moved, for the reason above: `meterLeft.update(…)` mutates in place,
        // and an in-place mutation is an assignment as far as observation is
        // concerned. Once a meter has settled — silence, a paused track, a
        // steady tone — these stop firing entirely and the analyzer stops
        // redrawing until something happens.
        advance(&meterLeft) { $0.update(linearPeak: diagnostics.peakLeft, elapsed: elapsed) }
        advance(&meterRight) { $0.update(linearPeak: diagnostics.peakRight, elapsed: elapsed) }
        advance(&vuLeft) { $0.update(linearAverage: diagnostics.vuLeft, elapsed: elapsed) }
        advance(&vuRight) { $0.update(linearAverage: diagnostics.vuRight, elapsed: elapsed) }
        advance(&correlation) {
            $0.update(rawCorrelation: diagnostics.correlation, elapsed: elapsed)
        }
    }

    /// Fold the plumbing counters into `readout`, on the heartbeat rather than
    /// on the meter beat.
    ///
    /// One assignment of the whole struct, guarded by an equality test, so a
    /// steady engine invalidates nothing at all. `EngineReadout` is `Equatable`
    /// precisely so this can be one comparison rather than ten.
    private func applyCounters(_ diagnostics: SystemAudioTap.Diagnostics) {
        var next = readout
        next.framesRendered = diagnostics.framesRendered
        next.buffersRendered = diagnostics.buffersRendered
        next.silentBuffers = diagnostics.silentBuffers
        next.mismatchedBuffers = diagnostics.mismatchedBuffers
        next.inputChannelCount = diagnostics.inputChannelCount
        next.dspFaults = diagnostics.dspFaults
        next.publicationCount = diagnostics.publicationCount
        guard next != readout else { return }
        readout = next
    }

    /// Run `step` over a copy of an observable value and write it back only if
    /// it changed — the "assignment, not change, is what fires observers"
    /// workaround `apply(_:elapsed:)` documents, in one place rather than
    /// spelled out at each of the five meters.
    private func advance<Value: Equatable>(
        _ storage: inout Value,
        _ step: (inout Value) -> Void
    ) {
        var next = storage
        step(&next)
        guard next != storage else { return }
        storage = next
    }
}

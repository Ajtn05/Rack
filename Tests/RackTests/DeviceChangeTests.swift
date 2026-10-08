import CoreAudio
import Darwin

@testable import AudioCore

/// The device-change policy, and the safety net beneath it.
///
/// The policy is pure by design — deciding *whether* a notification matters is
/// separated from the Core Audio plumbing that reports it — so it can be
/// tested without unplugging anything.
func runDeviceChangeTests() {
    let sampleRate = 48_000.0

    Check.suite("DeviceChangeDecision") {
        // The common case by a wide margin. Core Audio emits notifications for
        // a great deal that does not concern us, and rebuilding an aggregate
        // device on each one would be both slow and audible.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                currentDeviceUID: "A", currentSampleRate: 48_000
            ),
            .ignore,
            "an unchanged device is ignored"
        )

        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                currentDeviceUID: "B", currentSampleRate: 48_000
            ),
            .rebuild,
            "a different device rebuilds"
        )

        // Same device, new rate: the tap and aggregate are still valid, only
        // the coefficients are wrong. Recompiling is far cheaper than a
        // rebuild and does not interrupt the stream.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                currentDeviceUID: "A", currentSampleRate: 96_000
            ),
            .retune(sampleRate: 96_000),
            "a rate change on the same device retunes"
        )

        // Rates come from a driver as floating point; comparing for equality
        // would rebuild on rounding noise.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                currentDeviceUID: "A", currentSampleRate: 48_000.2
            ),
            .ignore,
            "a negligible rate difference is ignored"
        )

        // No default output device at all — briefly true while a device is
        // being removed. Waiting is right: there is nothing to rebuild onto,
        // and tearing down here would leave no audio and nothing to switch to.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                currentDeviceUID: nil, currentSampleRate: nil
            ),
            .ignore,
            "no default device yet means wait, not tear down"
        )
    }

    // Which microphone is in the aggregate is structural in exactly the way the
    // output device is — a sub-device, not a gain — so it belongs in this
    // decision rather than being handled somewhere on its own. Before it was
    // here, none of the four cases below produced any reaction at all: the
    // monitor stayed wired to whatever device had been default when the session
    // was built.
    Check.suite("DeviceChangeDecision — the microphone is part of the shape") {
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: "Mic1",
                currentDeviceUID: "A", currentSampleRate: 48_000,
                currentMicDeviceUID: "Mic1"
            ),
            .ignore,
            "an unchanged microphone is ignored, like an unchanged output"
        )

        // Someone changed the input in Sound settings while the monitor was
        // following the system default.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: "Mic1",
                currentDeviceUID: "A", currentSampleRate: 48_000,
                currentMicDeviceUID: "Mic2"
            ),
            .rebuild,
            "a different microphone rebuilds"
        )

        // The chosen interface was unplugged. Rebuilding to a session with no
        // microphone is right: staying wired to a device that is gone is how a
        // whole capture path ends up carrying nothing.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: "Mic1",
                currentDeviceUID: "A", currentSampleRate: 48_000,
                currentMicDeviceUID: nil
            ),
            .rebuild,
            "a microphone that has gone away rebuilds without it"
        )

        // And back again.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: nil,
                currentDeviceUID: "A", currentSampleRate: 48_000,
                currentMicDeviceUID: "Mic1"
            ),
            .rebuild,
            "a microphone that has come back rebuilds to include it"
        )

        // A rate change and a microphone change at once: the microphone wins,
        // because a retune keeps the sub-device list it was built with and
        // there would be nothing to retune the new microphone into.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: "Mic1",
                currentDeviceUID: "A", currentSampleRate: 96_000,
                currentMicDeviceUID: "Mic2"
            ),
            .rebuild,
            "a microphone change outranks a rate change"
        )

        // Nothing to do with the microphone still behaves exactly as it did.
        Check.equal(
            DeviceChangeDecision.decide(
                runningDeviceUID: "A", runningSampleRate: 48_000,
                runningMicDeviceUID: nil,
                currentDeviceUID: "A", currentSampleRate: 96_000,
                currentMicDeviceUID: nil
            ),
            .retune(sampleRate: 96_000),
            "no microphone either side leaves the rate rule untouched"
        )
    }

    // `.running` used to mean "every Core Audio call returned noErr", which is
    // a different claim from "audio is moving" — and the gap between them is
    // where an engine sits reporting itself healthy while its IOProc is never
    // called once. The bound is the part most worth testing: a check that is
    // wrong must cost a couple of gaps and then a visible fault, never an
    // endless teardown-and-rebuild loop.
    Check.suite("LivenessVerdict") {
        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 120, buffersAfter: 214,
                rebuildsAlreadyTried: 0, limit: 2
            ),
            .live,
            "a counter that moved is a path that runs"
        )

        // One callback is enough. The counter climbs on every IOProc
        // invocation whatever the audio turns out to be, which is the whole
        // point: silence is healthy and must never trigger a rebuild.
        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 120, buffersAfter: 121,
                rebuildsAlreadyTried: 0, limit: 2
            ),
            .live,
            "one callback in the window is proof enough"
        )

        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 0, buffersAfter: 0,
                rebuildsAlreadyTried: 0, limit: 2
            ),
            .rebuild,
            "built, started, and never called: rebuild and look again"
        )

        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 0, buffersAfter: 0,
                rebuildsAlreadyTried: 1, limit: 2
            ),
            .rebuild,
            "a second attempt is still worth making"
        )

        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 0, buffersAfter: 0,
                rebuildsAlreadyTried: 2, limit: 2
            ),
            .giveUp,
            "at the limit it reports a fault rather than rebuilding again"
        )
        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 0, buffersAfter: 0,
                rebuildsAlreadyTried: 9, limit: 2
            ),
            .giveUp,
            "and stays given up, so there is no way back into the loop"
        )

        // A dead path that had rendered before it died — a device pulled out
        // from under a running session, say. The counter is stuck, not zero,
        // and stuck is the condition that matters.
        Check.equal(
            LivenessVerdict.decide(
                buffersBefore: 48_000, buffersAfter: 48_000,
                rebuildsAlreadyTried: 0, limit: 2
            ),
            .rebuild,
            "a counter that stopped counts as dead, not just one that never started"
        )
    }

    Check.suite("AudioDevices — the self-loop guard") {
        // Our own aggregate, however it turns up. This is the one place a UID
        // is matched by name rather than by walking a membership list — but it
        // is *our own* naming scheme, not a heuristic about someone else's
        // device, so it is not the kind of name-matching the guard exists to
        // replace.
        Check.isTrue(
            AudioDevices.isRackLoop(
                uid: "dev.rack.aggregate.\(UUID().uuidString)", subDeviceUIDs: []
            ),
            "our own aggregate is always excluded"
        )
        Check.isTrue(
            !AudioDevices.isRackLoop(uid: "BuiltInSpeakerDevice", subDeviceUIDs: []),
            "ordinary hardware, no membership, is not a loop"
        )

        // The case the guard actually exists for: a multi-output device that
        // *contains* our aggregate somewhere in its membership. Nothing about
        // its own name or UID says so — only walking what it is built from
        // does, which is why this cannot be a name match on the device itself.
        Check.isTrue(
            AudioDevices.isRackLoop(
                uid: "com.apple.audio.MultiOutputDevice.1",
                subDeviceUIDs: ["BuiltInSpeakerDevice", "dev.rack.aggregate.abc123"]
            ),
            "a multi-output device containing our aggregate is a loop"
        )
        Check.isTrue(
            !AudioDevices.isRackLoop(
                uid: "com.apple.audio.MultiOutputDevice.2",
                subDeviceUIDs: ["BuiltInSpeakerDevice", "USBAudioDevice"]
            ),
            "one built from ordinary hardware is not"
        )

        // `kAudioAggregateDevicePropertyFullSubDeviceList` is documented to
        // flatten nested aggregates on its own, so one membership check has to
        // be enough however many layers deep the real device is built —
        // there is no recursive call in `isRackLoop` for that reason.
        Check.isTrue(
            AudioDevices.isRackLoop(
                uid: "com.apple.audio.MultiOutputDevice.3",
                subDeviceUIDs: ["USBAudioDevice", "dev.rack.aggregate.def456", "HDMIDevice"]
            ),
            "our aggregate nested arbitrarily deep still shows up in the flattened list"
        )
    }

    Check.suite("Biquad — unstable designs degrade to flat") {
        // An unstable filter does not sound wrong, it grows without bound.
        // Better a band that does nothing than one that produces full-scale
        // noise, so the design path refuses to publish one.
        let unstable = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: -3, a2: 2)
        Check.isTrue(!unstable.isStable, "the stability test recognises a bad set")

        // Every design the app can actually ask for stays inside the triangle.
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            for band in 0..<EQBank.bandCount {
                for gain in [-EQBank.maximumGainDecibels, 0, EQBank.maximumGainDecibels] {
                    let coefficients = EQBank.coefficients(
                        forBand: band, gainDecibels: gain, sampleRate: rate
                    )
                    Check.isTrue(
                        coefficients.isStable,
                        "band \(band) at \(Int(rate)) Hz, \(gain) dB is stable"
                    )
                }
            }
        }
    }

    Check.suite("rackRender — a non-finite sample trips the bypass") {
        // The safety net. If anything upstream hands us garbage, the filters
        // are poisoned: NaN propagates through the delay line and the channel
        // never recovers. The chain must notice and get out of the way.
        var parameters = DSPParameters.flat
        parameters.bandGains[5] = 12

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        context.pointee.dsp.smoothingCoefficient =
            DSPRenderState.smoothingCoefficient(forSampleRate: sampleRate)
        defer { context.deinitialize(count: 1); context.deallocate() }

        let frameCount = 512
        let sampleCount = frameCount * 2
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)

        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { inputStorage.deallocate() }
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        defer { outputStorage.deallocate() }

        for i in 0..<sampleCount { inputStorage[i] = 0.1 }
        inputStorage[64] = .nan

        let inputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        inputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: inputStorage
        )
        outputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage
        )

        Check.isTrue(!context.isBypassed, "not bypassed before the fault")
        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )

        Check.isTrue(context.isBypassed, "the panic bypass engaged")
        Check.equal(context.dspFaults, 1, "the fault was counted")

        // The offending buffer is silenced rather than sent on. A click is
        // recoverable; full-scale noise into headphones is not.
        var allFinite = true
        for i in 0..<sampleCount where !outputStorage[i].isFinite { allFinite = false }
        Check.isTrue(allFinite, "no non-finite sample reaches the device")

        // And having bypassed, the next buffer passes through cleanly rather
        // than staying poisoned.
        for i in 0..<sampleCount { inputStorage[i] = 0.25 }
        inputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: inputStorage
        )
        outputList[0] = AudioBuffer(
            mNumberChannels: 2, mDataByteSize: byteCount, mData: outputStorage
        )
        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )

        var recovered = true
        for i in 0..<sampleCount where outputStorage[i] != 0.25 { recovered = false }
        Check.isTrue(recovered, "audio flows again, unprocessed, after a fault")
    }
}

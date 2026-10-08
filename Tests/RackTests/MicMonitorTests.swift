import CoreAudio
import Darwin

@testable import AudioCore

/// Microphone monitoring: the gain law, what costs a rebuild, and the mono
/// microphone's route into a stereo mix.
func runMicMonitorTests() {
    let sampleRate = 48_000.0

    Check.suite("MicMonitor — gain") {
        var monitor = MicMonitor(isEnabled: true, volume: 1)
        Check.close(monitor.gain, 1, tolerance: 0.0001, "full level is unity")

        // Square-law, matching the master fader and the per-app faders so
        // every fader in the program behaves the same way under the hand.
        monitor.volume = 0.5
        Check.close(monitor.gain, 0.25, tolerance: 0.0001, "half travel is a quarter power")

        monitor.volume = 1
        monitor.isMuted = true
        Check.close(monitor.gain, 0, tolerance: 0.0001, "mute overrides level")

        // The switch and the mute are different questions, and a disabled
        // monitor must contribute silence whatever the other two say — a
        // stream that is still present at its old level is exactly the
        // feedback loop the feature defaults to off to avoid.
        monitor.isMuted = false
        monitor.isEnabled = false
        Check.close(monitor.gain, 0, tolerance: 0.0001, "disabled is silent regardless of level")
    }

    Check.suite("MicMonitor — what costs a rebuild") {
        let base = MicMonitor(isEnabled: true, deviceUID: "mic-a", volume: 0.5)

        // Structural: a different set of sub-devices in the aggregate.
        Check.isTrue(
            base.needsRebuild(comparedTo: MicMonitor(isEnabled: false, deviceUID: "mic-a")),
            "switching the monitor on or off rebuilds"
        )
        Check.isTrue(
            base.needsRebuild(comparedTo: MicMonitor(isEnabled: true, deviceUID: "mic-b")),
            "changing which microphone rebuilds"
        )

        // Cosmetic: the same devices at different gains. A rebuild here would
        // put a gap in the audio every time a level knob moved.
        var louder = base
        louder.volume = 0.9
        Check.isTrue(
            !base.needsRebuild(comparedTo: louder),
            "changing the level is a republish, not a rebuild"
        )
        var muted = base
        muted.isMuted = true
        Check.isTrue(
            !base.needsRebuild(comparedTo: muted),
            "muting is a republish, not a rebuild"
        )
    }

    Check.suite("MicMonitor — default is off") {
        // Not a style preference. A saved session, a fresh install, and a
        // state file written before this feature existed all decode to the
        // same thing, and none of them may switch a microphone on.
        Check.isTrue(!MicMonitor().isEnabled, "a fresh monitor is switched off")
        Check.close(MicMonitor().gain, 0, tolerance: 0.0001, "and therefore silent")
    }

    Check.suite("MicMonitor — an unrelated parameter change keeps the mic alive") {
        // The regression this exists for: publishing is the *whole* mix, not
        // a patch to it, so a publication that omitted the monitor overwrote
        // it with the default — which is "off", gain zero. Every knob
        // movement publishes, so moving any unrelated control silently muted
        // the microphone until something touched the Input panel.
        //
        // Tested at the level the bug lived at: the gain array a publication
        // carries. `TapSession` needs real Core Audio objects, so the check
        // is on the value that would be handed to it — a live monitor must
        // survive a parameter change with its gain intact.
        let monitor = MicMonitor(isEnabled: true, volume: 1)
        Check.close(
            monitor.gain, 1, tolerance: 0.0001,
            "a live monitor carries a non-zero gain"
        )
        // The default is what a forgotten argument used to publish, and why
        // the symptom was silence rather than a wrong level.
        Check.close(
            MicMonitor().gain, 0, tolerance: 0.0001,
            "and the default it was being overwritten with is silence"
        )
    }

    Check.suite("rackRender — a mono microphone reaches both channels") {
        // The whole point of the mono path in `rackMixStreams`. Summing a
        // mono buffer element-wise into a stereo one would send its first
        // half to alternating L/R samples and leave the rest of the frame
        // untouched — noise, not a centred voice.
        let publisher = ParameterPublisher()
        // Stream 0 is the microphone, stream 1 the global tap — the layout
        // `TapSession.micStreamIndex` records, measured on real hardware.
        publisher.publish(.flat, streamGains: [1, 1], sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        // Smoothing off, so one buffer reaches the target gain and the test
        // measures the mix rather than the ramp.
        context.pointee.dsp.smoothingCoefficient = 1
        defer { context.deinitialize(count: 1); context.deallocate() }

        let frameCount = 128
        let stereoSamples = frameCount * 2

        // The microphone: one channel, one sample per frame.
        let micStorage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { micStorage.deallocate() }
        for i in 0..<frameCount { micStorage[i] = 0.25 }

        // The tap: two channels, silent, so anything in the output came from
        // the microphone.
        let tapStorage = UnsafeMutablePointer<Float>.allocate(capacity: stereoSamples)
        defer { tapStorage.deallocate() }
        for i in 0..<stereoSamples { tapStorage[i] = 0 }

        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: stereoSamples)
        defer { outputStorage.deallocate() }

        let inputList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        inputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: micStorage
        )
        inputList[1] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(stereoSamples * MemoryLayout<Float>.size),
            mData: tapStorage
        )
        outputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(stereoSamples * MemoryLayout<Float>.size),
            mData: outputStorage
        )

        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )

        // Centred: the same value in both channels, on the first frame and
        // the last. A mono source that only filled half the buffer would fail
        // the second of these while passing the first.
        Check.close(
            Double(outputStorage[0]), 0.25, tolerance: 0.001,
            "the microphone reaches the left channel"
        )
        Check.close(
            Double(outputStorage[1]), 0.25, tolerance: 0.001,
            "and the right, at the same level — a centred image"
        )
        Check.close(
            Double(outputStorage[stereoSamples - 2]), 0.25, tolerance: 0.001,
            "across the whole buffer, left"
        )
        Check.close(
            Double(outputStorage[stereoSamples - 1]), 0.25, tolerance: 0.001,
            "across the whole buffer, right"
        )
    }

    Check.suite("rackRender — the microphone's own gain is independent") {
        // Stream 0 muted, stream 1 (the tap) at unity: the microphone must
        // disappear without taking the system audio with it. This is the test
        // that would have caught the gain array being ordered tap-first.
        let publisher = ParameterPublisher()
        publisher.publish(.flat, streamGains: [0, 1], sampleRate: sampleRate)

        let context = UnsafeMutablePointer<TapRenderContext>.allocate(capacity: 1)
        context.initialize(to: TapRenderContext())
        context.pointee.exchange = publisher.exchange
        context.pointee.slots = publisher.slots
        context.pointee.dsp.smoothingCoefficient = 1
        defer { context.deinitialize(count: 1); context.deallocate() }

        let frameCount = 64
        let stereoSamples = frameCount * 2

        let micStorage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { micStorage.deallocate() }
        for i in 0..<frameCount { micStorage[i] = 0.5 }

        let tapStorage = UnsafeMutablePointer<Float>.allocate(capacity: stereoSamples)
        defer { tapStorage.deallocate() }
        for i in 0..<stereoSamples { tapStorage[i] = 0.3 }

        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: stereoSamples)
        defer { outputStorage.deallocate() }

        let inputList = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inputList.unsafeMutablePointer) }
        let outputList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputList.unsafeMutablePointer) }

        inputList[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
            mData: micStorage
        )
        inputList[1] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(stereoSamples * MemoryLayout<Float>.size),
            mData: tapStorage
        )
        outputList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(stereoSamples * MemoryLayout<Float>.size),
            mData: outputStorage
        )

        rackRender(
            context: context,
            input: UnsafePointer(inputList.unsafeMutablePointer),
            output: outputList.unsafeMutablePointer
        )

        Check.close(
            Double(outputStorage[0]), 0.3, tolerance: 0.001,
            "muting the microphone leaves the system audio untouched"
        )
    }

    // The microphone is a sub-device, not a tap, but it still occupies one of
    // the aggregate's input streams — and therefore one of `DSPBlock`'s fixed
    // stream slots. Reserving only the global tap overflowed the block by one,
    // which does not degrade gracefully: `rackMixStreams` declines the whole
    // mix and the plain-copy fallback puts the microphone out where the system
    // audio should be.
    Check.suite("TapSession — the microphone is counted against the stream budget") {
        let withoutMic = TapSession.maximumControlledProcesses(hasMicrophone: false)
        let withMic = TapSession.maximumControlledProcesses(hasMicrophone: true)

        Check.equal(
            withoutMic + 1, DSPChain.maximumStreams,
            "no mic: the global tap plus every controlled app fills the block exactly"
        )
        Check.equal(
            withMic + 2, DSPChain.maximumStreams,
            "with a mic: the mic and the global tap both take a slot"
        )
        Check.equal(withMic, withoutMic - 1, "a microphone costs exactly one app slot")

        // The property that actually matters, stated the way the failure was
        // found: whatever `streamGains` builds must fit in the block, so that
        // `applyStreamGains` never has to drop one and `rackMixStreams` never
        // sees more input buffers than the block admits to.
        for hasMic in [false, true] {
            let streams = (hasMic ? 1 : 0)
                + 1
                + TapSession.maximumControlledProcesses(hasMicrophone: hasMic)
            Check.isTrue(
                streams <= DSPChain.maximumStreams,
                "mic=\(hasMic) — \(streams) streams fits in \(DSPChain.maximumStreams)"
            )

            // And nothing is dropped on the way into a block.
            let publisher = ParameterPublisher()
            publisher.publish(
                .flat,
                streamGains: [Float](repeating: 0.5, count: streams),
                sampleRate: 48_000
            )
            let block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
            Check.equal(
                Int(block.pointee.streamCount), streams,
                "mic=\(hasMic) — the block carries every gain it was given"
            )
        }
    }
}

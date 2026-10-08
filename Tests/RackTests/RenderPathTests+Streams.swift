import CoreAudio
import Darwin

@testable import AudioCore

/// Buffer-walking edge cases — a short deinterleaved partner must not be
/// read or written past its own end.
func runStreamsRenderPathTests() {
    Check.suite("rackRender — missing input storage silences the whole destination") {
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer {
            context.pointee.reverb.free()
            context.pointee.delay.free()
            context.deinitialize(count: 1)
            context.deallocate()
        }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer) }
        var samples = [Float](repeating: 0.75, count: 32)
        samples.withUnsafeMutableBufferPointer { storage in
            let bytes = UInt32(storage.count * MemoryLayout<Float>.size)
            input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: nil)
            output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: storage.baseAddress!)
            rackRender(context: context, input: UnsafePointer(input.unsafeMutablePointer), output: output.unsafeMutablePointer)
        }
        Check.isTrue(samples.allSatisfy { $0 == 0 }, "stale output is never replayed")
        Check.equal(context.mismatchedBuffers, 1, "missing storage is counted as a mismatch")
        Check.equal(context.silentBuffers, 1, "and the input was silent")
    }

    Check.suite("rackRender — a published rate change retunes effect timing and clears old tails") {
        let publisher = ParameterPublisher()
        let context = makeContext(publisher)
        defer {
            context.pointee.reverb.free()
            context.pointee.delay.free()
            context.deinitialize(count: 1)
            context.deallocate()
        }
        var parameters = DSPParameters.flat
        parameters.isReverbEnabled = true
        parameters.isDelayEnabled = true
        parameters.delayPreset = .echo
        publisher.publish(parameters, sampleRate: 48_000)
        _ = renderStream(context: context, frequency: 220, settlingBuffers: 20)
        publisher.publish(parameters, sampleRate: 96_000)
        // Publication must not touch render state from the writer's thread.
        Check.equal(context.pointee.sampleRate, 48_000, "the reader owns the rate transition")
        let retuned = renderStream(context: context, frequency: 220, amplitude: 0)
        Check.equal(peak(retuned.output), 0, "old-rate effect tails are cleared")
        Check.equal(context.pointee.sampleRate, 96_000, "the next buffer adopts the new rate")
        Check.equal(
            context.pointee.dsp.smoothingCoefficient,
            DSPRenderState.smoothingCoefficient(forSampleRate: 96_000),
            "gain smoothing follows the rate"
        )
        let echo = context.pointee.delay.voiceA
        Check.equal(echo.left.length, Int32(33_600), "350 ms is 33600 samples at 96 kHz")
        let room = ReverbCoefficients.compile(
            preset: parameters.reverbPreset, wetAmount: parameters.reverbWetAmount,
            isEnabled: true, sampleRate: 96_000
        )
        Check.equal(context.pointee.reverb.voiceA.leftLines.0.length, room.lineSamplesLeft.0,
                    "the same reverb preset receives new-rate line lengths")
    }

    // Every deinterleaved walk in the render path pairs an even buffer with the
    // odd one after it — stereo width, reverb, echo, crossfeed and the limiter
    // through `rackWalkStereoPairs`, plus the correlation and goniometer
    // captures. All of them took the frame count from the *left* buffer and
    // indexed the right one with it. A shorter partner is then written and read
    // past its own end: a heap overrun, on the audio thread, where nothing can
    // recover from it.
    //
    // Whether Core Audio ever hands us a mismatched pair is not the point. The
    // buffer says how long it is; nothing here is entitled to assume its
    // neighbour agrees.
    Check.suite("rackRender — a short deinterleaved partner is not overrun") {
        let leftFrames = 512
        let rightFrames = 192
        let slack = 512
        let sentinel: Float = -999

        /// A deinterleaved pair whose right buffer is shorter than its left,
        /// over-allocated and sentinel-filled past what each claims to own.
        func makePair() -> (
            list: UnsafeMutableAudioBufferListPointer,
            left: UnsafeMutablePointer<Float>,
            right: UnsafeMutablePointer<Float>
        ) {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: leftFrames + slack)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: rightFrames + slack)
            left.initialize(repeating: sentinel, count: leftFrames + slack)
            right.initialize(repeating: sentinel, count: rightFrames + slack)
            for i in 0..<leftFrames { left[i] = 0 }
            for i in 0..<rightFrames { right[i] = 0 }

            let list = AudioBufferList.allocate(maximumBuffers: 2)
            list[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(leftFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(left)
            )
            list[1] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(rightFrames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(right)
            )
            return (list, left, right)
        }

        func sentinelsIntact(
            _ buffer: UnsafeMutablePointer<Float>, ownedFrames: Int
        ) -> Bool {
            for i in ownedFrames..<(ownedFrames + slack) where buffer[i] != sentinel {
                return false
            }
            return true
        }

        // Everything that walks a deinterleaved pair, switched on at once: the
        // three stereo effects, crossfeed, the limiter, and both captures.
        var parameters = DSPParameters.flat
        parameters.stereoWidth = 0.4
        parameters.isReverbEnabled = true
        parameters.reverbWetAmount = 0.5
        parameters.isDelayEnabled = true
        parameters.delayWetAmount = 0.5
        parameters.isCrossfeedEnabled = true
        parameters.crossfeedAmount = 0.8
        parameters.isLimiterEnabled = true

        let publisher = ParameterPublisher()
        let context = makeContext(publisher)
        defer {
            context.pointee.reverb.free()
            context.pointee.delay.free()
            context.deinitialize(count: 1)
            context.deallocate()
        }

        let goniometer = GoniometerRing()
        goniometer.isEnabled = true
        context.pointee.goniometer = goniometer.header

        let input = makePair()
        let output = makePair()
        defer {
            free(input.list.unsafeMutablePointer)
            free(output.list.unsafeMutablePointer)
            input.left.deallocate(); input.right.deallocate()
            output.left.deallocate(); output.right.deallocate()
        }

        for i in 0..<leftFrames { input.left[i] = 0.4 }
        for i in 0..<rightFrames { input.right[i] = -0.3 }

        publisher.publish(parameters, streamGains: [], sampleRate: renderPathSampleRate)

        // More than one pass, so the delay lines and crossfade get going and
        // every pass has really run.
        for _ in 0..<4 {
            rackRender(
                context: context,
                input: UnsafePointer(input.list.unsafeMutablePointer),
                output: output.list.unsafeMutablePointer
            )
        }

        Check.isTrue(
            sentinelsIntact(output.right, ownedFrames: rightFrames),
            "nothing is written past the short right buffer's own end"
        )
        Check.isTrue(
            sentinelsIntact(output.left, ownedFrames: leftFrames),
            "nor past the long left buffer's"
        )
        Check.isTrue(
            sentinelsIntact(input.right, ownedFrames: rightFrames),
            "and the input's short buffer is untouched past its end"
        )
        // The frames the pair genuinely shares are still processed — bounding
        // the walk must not turn into skipping it.
        var touched = false
        for i in 0..<rightFrames where output.right[i] != 0 { touched = true; break }
        Check.isTrue(touched, "the frames both buffers do own are still processed")
    }
}

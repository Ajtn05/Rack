import CoreAudio
import Darwin

@testable import AudioCore

/// Balance, crossfeed, publication, and bypass — stereo-image and
/// control-plane basics that do not fit any other group.
func runBalanceRenderPathTests() {
    Check.suite("rackRender — balance reaches the output") {
        var parameters = DSPParameters.flat
        parameters.balance = -1  // hard left

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (_, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 8
        )

        var leftPeak: Float = 0
        var rightPeak: Float = 0
        for frame in 0..<renderPathFrameCount {
            leftPeak = max(leftPeak, abs(output[frame * 2]))
            rightPeak = max(rightPeak, abs(output[frame * 2 + 1]))
        }
        Check.isTrue(leftPeak > 0.2, "hard left keeps the left channel")
        Check.close(Double(rightPeak), 0, tolerance: 0.001, "hard left silences the right")
    }

    Check.suite("rackRender — crossfeed bleeds into the silent channel when enabled") {
        // Balance hard left first, so the signal reaching crossfeed is on
        // the left channel only — the same asymmetric setup the balance
        // test above proves leaves the right channel silent. Crossfeed
        // running after that should put some of it back.
        var parameters = DSPParameters.flat
        parameters.balance = -1
        parameters.isCrossfeedEnabled = true
        parameters.crossfeedAmount = 1

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (_, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 8
        )

        var rightPeak: Float = 0
        var allFinite = true
        for frame in 0..<renderPathFrameCount {
            let sample = output[frame * 2 + 1]
            if !sample.isFinite { allFinite = false }
            rightPeak = max(rightPeak, abs(sample))
        }
        Check.isTrue(allFinite, "crossfeed output stays finite")
        Check.isTrue(rightPeak > 0.001, "crossfeed bleeds some of the left channel into the silent right")
    }

    Check.suite("rackRender — a later publication takes effect") {
        // The audio thread must pick up a change made after it started
        // rendering. This is the slider-drag case.
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        _ = renderStream(context: context, frequency: 1000, settlingBuffers: 4)

        var parameters = DSPParameters.flat
        parameters.preampDecibels = -12
        publisher.publish(parameters, sampleRate: renderPathSampleRate)

        let (input, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 8
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(
            decibels, -12, tolerance: 0.2,
            "parameters published mid-stream reach the audio thread"
        )
    }

    Check.suite("rackRender — bypass") {
        var parameters = DSPParameters.flat
        parameters.bandGains[5] = 12
        parameters.isBypassed = true

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 4
        )
        var identical = true
        for i in 0..<input.count where input[i] != output[i] { identical = false }
        Check.isTrue(identical, "the parameter bypass passes audio through untouched")

        // And the panic flag, independently.
        var live = DSPParameters.flat
        live.bandGains[5] = 12
        publisher.publish(live, sampleRate: renderPathSampleRate)
        context.isBypassed = true
        let (panicInput, panicOutput) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 4
        )
        identical = true
        for i in 0..<panicInput.count where panicInput[i] != panicOutput[i] { identical = false }
        Check.isTrue(identical, "the panic bypass passes audio through untouched")
    }

}

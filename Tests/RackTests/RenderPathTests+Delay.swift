import CoreAudio
import Darwin

@testable import AudioCore

/// Delay reaching the output, and a preset switch staying finite and bounded.
func runDelayRenderPathTests() {
    Check.suite("rackRender — delay reaches the output when enabled") {
        var parameters = DSPParameters.flat
        parameters.isDelayEnabled = true
        parameters.delayWetAmount = 1
        parameters.delayPreset = .echo

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        // A burst of tone, then several buffers of silence — long enough to
        // clear Echo's ~350 ms tap and show a repeat if the delay is
        // actually in the signal path.
        _ = renderStream(context: context, frequency: 400, settlingBuffers: 6)

        var sawEnergyDuringSilence = false
        for _ in 0..<8 {
            let (_, output) = renderStream(context: context, frequency: 0, settlingBuffers: 0)
            if peak(output) > 0.0005 { sawEnergyDuringSilence = true }
        }

        Check.isTrue(
            sawEnergyDuringSilence,
            "an echo is still audible after the dry signal stops"
        )
    }

    Check.suite("rackRender — a delay preset switch stays finite and bounded") {
        // The case the crossfade exists for: switching Echo to Dub
        // mid-stream, with the tap time changing, must never produce a
        // spike or a non-finite sample.
        var parameters = DSPParameters.flat
        parameters.isDelayEnabled = true
        parameters.delayWetAmount = 1
        parameters.delayPreset = .echo

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        _ = renderStream(context: context, frequency: 200, settlingBuffers: 8)

        parameters.delayPreset = .dub
        publisher.publish(parameters, sampleRate: renderPathSampleRate)

        var worstPeak: Float = 0
        var allFinite = true
        for _ in 0..<40 {
            let (_, output) = renderStream(context: context, frequency: 200, settlingBuffers: 0)
            for sample in output {
                if !sample.isFinite { allFinite = false }
                worstPeak = max(worstPeak, abs(sample))
            }
        }

        Check.isTrue(allFinite, "every sample through a preset switch is finite")
        Check.isTrue(worstPeak < 4, "the switch does not spike the level (worst \(worstPeak))")
    }

}

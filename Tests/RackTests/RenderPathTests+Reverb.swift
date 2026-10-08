import CoreAudio
import Darwin

@testable import AudioCore

/// Reverb reaching the output, and a preset switch staying finite and bounded.
func runReverbRenderPathTests() {
    Check.suite("rackRender — reverb reaches the output when enabled") {
        var parameters = DSPParameters.flat
        parameters.isReverbEnabled = true
        parameters.reverbWetAmount = 1
        parameters.reverbPreset = .hall

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        // A burst of tone to excite the network, then several buffers of
        // silence (frequency 0 is a constant-zero "tone") long enough to
        // clear the pre-delay and show a decaying tail if the reverb is
        // actually in the signal path.
        _ = renderStream(context: context, frequency: 400, settlingBuffers: 6)

        var sawEnergyDuringSilence = false
        for _ in 0..<8 {
            let (_, output) = renderStream(context: context, frequency: 0, settlingBuffers: 0)
            if peak(output) > 0.0005 { sawEnergyDuringSilence = true }
        }

        Check.isTrue(
            sawEnergyDuringSilence,
            "a decaying tail is still audible after the dry signal stops"
        )
    }

    Check.suite("rackRender — a reverb preset switch stays finite and bounded") {
        // The case the crossfade exists for: switching Hall to Stadium
        // mid-stream, with both delay-line lengths and decay times
        // changing at once, must never produce a spike or a non-finite
        // sample — the failure mode a hard splice between two networks
        // would risk.
        var parameters = DSPParameters.flat
        parameters.isReverbEnabled = true
        parameters.reverbWetAmount = 1
        parameters.reverbPreset = .hall

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        _ = renderStream(context: context, frequency: 200, settlingBuffers: 8)

        parameters.reverbPreset = .stadium
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

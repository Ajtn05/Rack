import CoreAudio
import Darwin

@testable import AudioCore

/// EQ/chain-order basics: passthrough, boost/cut bands, band isolation,
/// preamp, volume, boost-vs-volume interaction, tone, headroom compensation.
func runEQRenderPathTests() {
    Check.suite("rackRender — passthrough is bit-exact") {
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(context: context, frequency: 1000)

        var identical = true
        for i in 0..<input.count where input[i] != output[i] { identical = false }
        Check.isTrue(identical, "flat parameters pass the buffer through untouched")
        Check.isTrue(context.framesRendered > 0, "frames were counted")
    }

    Check.suite("rackRender — a boosted band reaches the output") {
        // This is the one that matters: does moving a slider change the audio?
        // Headroom compensation is on by default and exists precisely to stop
        // a boosted band from raising the output — which is a different
        // question, covered on its own below — so it is defeated here to
        // isolate the band's own gain.
        let bandIndex = 5  // 1 kHz
        var parameters = DSPParameters.flat
        parameters.bandGains[bandIndex] = 12
        parameters.isHeadroomCompensationEnabled = false

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context,
            frequency: EQBank.frequencies[bandIndex],
            settlingBuffers: 8
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(
            decibels, 12, tolerance: 0.5,
            "a +12 dB band at its centre frequency raises the output by 12 dB"
        )
    }

    Check.suite("rackRender — a cut band reaches the output") {
        let bandIndex = 5
        var parameters = DSPParameters.flat
        parameters.bandGains[bandIndex] = -12

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context,
            frequency: EQBank.frequencies[bandIndex],
            settlingBuffers: 8
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(decibels, -12, tolerance: 0.5, "a −12 dB band cuts by 12 dB")
    }

    Check.suite("rackRender — a band leaves other frequencies alone") {
        // Headroom compensation would otherwise cut this frequency too — it
        // is a broadband trim, not a shape — so it is defeated here for the
        // same reason as above.
        var parameters = DSPParameters.flat
        parameters.bandGains[5] = 12  // 1 kHz
        parameters.isHeadroomCompensationEnabled = false

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        // Four octaves below the boosted band.
        let (input, output) = renderStream(
            context: context, frequency: 62.5, settlingBuffers: 8
        )

        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(decibels, 0, tolerance: 0.6, "a distant frequency is untouched")
    }

    Check.suite("rackRender — preamp reaches the output") {
        var parameters = DSPParameters.flat
        parameters.preampDecibels = -6

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 8
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(decibels, -6, tolerance: 0.2, "preamp attenuates by its setting")
    }

    Check.suite("rackRender — volume reaches the output") {
        // Volume is a real attenuator, not merely an input to the boost
        // contour. The taper is dB-linear across 48 dB, so half travel is
        // exactly half the range.
        var parameters = DSPParameters.flat
        parameters.volume = 0.5

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context, frequency: 1000, settlingBuffers: 8
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(decibels, -24, tolerance: 0.2, "half travel is −24 dB")
    }

    Check.suite("rackRender — boost lifts bass as volume falls") {
        // With volume down and boost up, the bass shelf must show a lift
        // *relative to* the attenuation the volume control applied. Headroom
        // compensation is defeated here for the same reason as the EQ tests
        // above: left on, it would cut the output by the same broadband
        // amount the shelf just lifted it, and the two would cancel exactly
        // where this test is trying to measure the lift.
        var quiet = DSPParameters.flat
        quiet.volume = 0.5
        quiet.isHeadroomCompensationEnabled = false

        var quietWithBoost = quiet
        quietWithBoost.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels

        func level(_ parameters: DSPParameters, frequency: Double) -> Double {
            let publisher = ParameterPublisher()
            publisher.publish(parameters, sampleRate: renderPathSampleRate)
            let context = makeContext(publisher)
            defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }
            let (input, output) = renderStream(
                context: context, frequency: frequency, settlingBuffers: 12
            )
            return 20 * log10(Double(peak(output) / peak(input)))
        }

        let plainBass = level(quiet, frequency: 60)
        let liftedBass = level(quietWithBoost, frequency: 60)
        Check.isTrue(
            liftedBass > plainBass + 3,
            "boost lifts the bass at reduced volume "
                + "(\(plainBass) → \(liftedBass) dB)"
        )

        // And leaves the midrange, which needs no compensation, alone.
        let plainMid = level(quiet, frequency: 1000)
        let liftedMid = level(quietWithBoost, frequency: 1000)
        Check.close(
            liftedMid, plainMid, tolerance: 0.5,
            "boost leaves the midrange alone"
        )
    }

    Check.suite("rackRender — tone control reaches the output") {
        var parameters = DSPParameters.flat
        parameters.toneBassDecibels = -DSPParameters.toneMaximumDecibels

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context, frequency: 30, settlingBuffers: 12
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(
            decibels, -DSPParameters.toneMaximumDecibels, tolerance: 0.5,
            "a full bass cut reaches the output well below the shelf's corner"
        )
    }

    Check.suite("rackRender — headroom compensation caps the peak") {
        // The case the whole feature exists for: raising Boost must not raise
        // the level leaving the engine. Same setup as the contour test above,
        // but with headroom compensation left on this time — the shelf's own
        // gain at 30 Hz and the cut it earns are set by the same combined
        // peak, so what reaches the output should be no more than the volume
        // control's own attenuation.
        var parameters = DSPParameters.flat
        parameters.volume = 0.5
        parameters.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: renderPathSampleRate)
        let context = makeContext(publisher)
        defer { context.pointee.reverb.free(); context.pointee.delay.free(); context.deinitialize(count: 1); context.deallocate() }

        let (input, output) = renderStream(
            context: context, frequency: 30, settlingBuffers: 12
        )
        let decibels = 20 * log10(Double(peak(output) / peak(input)))
        Check.close(
            decibels, parameters.volumeDecibels, tolerance: 0.5,
            "boost adds no gain on top of the volume control once compensated "
                + "(\(decibels) dB, volume alone is \(parameters.volumeDecibels) dB)"
        )
    }

}

import Darwin

@testable import AudioCore

/// The curve is the only place a user can see what the equalizer is doing
/// without listening to it, so it has to be right for the same reason the
/// filters do. A plot that is merely plausible is worse than no plot: it looks
/// like measurement and is not.
func runFrequencyResponseTests() {
    let sampleRate = 48_000.0

    /// Response at one frequency, for the many single-point assertions below.
    func response(
        _ parameters: DSPParameters,
        at frequency: Double,
        sampleRate: Double = 48_000
    ) -> Double {
        FrequencyResponse(parameters: parameters, sampleRate: sampleRate)
            .magnitudeResponse(at: [frequency])[0]
    }

    Check.suite("FrequencyResponse — flat is flat") {
        let curve = FrequencyResponse(parameters: .flat, sampleRate: sampleRate)
        let frequencies = FrequencyResponse.logSpacedFrequencies(count: 120)
        let magnitudes = curve.magnitudeResponse(at: frequencies)

        Check.equal(magnitudes.count, 120, "one magnitude per frequency")

        var worst = 0.0
        for magnitude in magnitudes { worst = max(worst, abs(magnitude)) }
        Check.close(worst, 0, tolerance: 0.000_001, "every point of a flat chain is 0 dB")
    }

    Check.suite("FrequencyResponse — preamp offsets the whole curve") {
        for trim in [-12.0, -6.0, 6.0, 12.0] {
            var parameters = DSPParameters.flat
            parameters.preampDecibels = trim

            let curve = FrequencyResponse(parameters: parameters, sampleRate: sampleRate)
            let magnitudes = curve.magnitudeResponse(at: [20, 200, 2000, 15_000])
            for magnitude in magnitudes {
                Check.close(
                    magnitude, trim, tolerance: 0.000_001,
                    "\(trim) dB of trim moves every point by \(trim) dB"
                )
            }
        }
    }

    Check.suite("FrequencyResponse — one band shows up where it should") {
        // Band 5 is the 1 kHz peaking band.
        var parameters = DSPParameters.flat
        parameters.bandGains[5] = 12

        Check.close(
            response(parameters, at: 1000), 12, tolerance: 0.01,
            "a 12 dB band reaches 12 dB at its centre"
        )
        Check.close(
            response(parameters, at: 20), 0, tolerance: 0.3,
            "and leaves the bottom of the range alone"
        )
        Check.close(
            response(parameters, at: 20_000), 0, tolerance: 0.5,
            "and the top of it"
        )
    }

    Check.suite("FrequencyResponse — cascaded sections add in decibels") {
        // Two neighbouring bands, each boosted. At a frequency well away from
        // both, the curve is the sum of what each contributes there — that is
        // the property the whole single-line display rests on.
        var parameters = DSPParameters.flat
        parameters.bandGains[4] = 6      // 500 Hz
        parameters.bandGains[6] = -9     // 2 kHz

        var only500 = DSPParameters.flat
        only500.bandGains[4] = 6
        var only2k = DSPParameters.flat
        only2k.bandGains[6] = -9

        for probe in [125.0, 500.0, 1000.0, 2000.0, 8000.0] {
            Check.close(
                response(parameters, at: probe),
                response(only500, at: probe) + response(only2k, at: probe),
                tolerance: 0.000_001,
                "the combined curve at \(Int(probe)) Hz is the sum of its sections"
            )
        }
    }

    Check.suite("FrequencyResponse — the boost contour is in the curve") {
        // Boost on, volume all the way up: no attenuation, so no
        // compensation, so nothing to see. This is the case that would pass
        // trivially if the contour had simply been left out of the sweep, so
        // the boosted case below is the one that matters.
        var quiet = DSPParameters.flat
        quiet.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels
        quiet.volume = 1
        Check.close(
            response(quiet, at: 40), 0, tolerance: 0.01,
            "boost at full volume changes nothing"
        )

        // Turned down far enough for full compensation. The bass shelf reaches
        // exactly the depth the knob is set to, below its corner.
        quiet.volume = 0.5   // −24 dB, past the 15 dB compensation point
        let bass = response(quiet, at: 30)
        Check.close(
            bass, quiet.boostDepthDecibels, tolerance: 0.5,
            "boost at low volume lifts the bottom by its full depth"
        )

        let treble = response(quiet, at: 19_000)
        Check.close(
            treble, quiet.boostDepthDecibels * DSPParameters.boostTrebleRatio, tolerance: 0.6,
            "and the top by its own, shallower, depth"
        )

        Check.close(
            response(quiet, at: 1000), 0, tolerance: 0.6,
            "and leaves the midrange where it was"
        )
    }

    Check.suite("FrequencyResponse — the tone control is in the curve") {
        var parameters = DSPParameters.flat
        parameters.toneBassDecibels = 9
        parameters.toneTrebleDecibels = -6

        Check.close(
            response(parameters, at: 20), 9, tolerance: 0.5,
            "the bass shelf reaches its set gain well below its corner"
        )
        Check.close(
            response(parameters, at: 20_000), -6, tolerance: 0.5,
            "and the treble shelf reaches its own, well above its corner"
        )
        Check.close(
            response(parameters, at: 1000), 0, tolerance: 0.6,
            "leaving the midrange alone"
        )

        // TONE DEFEAT bypasses both shelves without moving the knobs.
        parameters.isToneDefeated = true
        Check.close(
            response(parameters, at: 20), 0, tolerance: 0.01,
            "defeated, the bass shelf contributes nothing to the curve"
        )
        Check.close(
            response(parameters, at: 20_000), 0, tolerance: 0.01,
            "neither does the treble shelf"
        )
        Check.close(
            parameters.toneBassDecibels, 9, tolerance: 0.0001,
            "though the stored bass position is untouched"
        )
    }

    Check.suite("FrequencyResponse — headroom compensation targets the peak") {
        // Two shelves that both lift the bottom end, from the graphic EQ and
        // the tone control. Both decay monotonically away from the bottom of
        // the plotted range, so their peaks coincide at its edge and the
        // combined peak is exactly their sum there — the reinforcement
        // headroom compensation exists to catch.
        var parameters = DSPParameters.flat
        parameters.bandGains[0] = 8   // 31.25 Hz low shelf
        parameters.toneBassDecibels = 5

        var onlyBand = DSPParameters.flat
        onlyBand.bandGains[0] = 8
        var onlyTone = DSPParameters.flat
        onlyTone.toneBassDecibels = 5

        let combined = FrequencyResponse(parameters: parameters, sampleRate: sampleRate)
            .maximumGainDecibels
        let bandAlone = FrequencyResponse(parameters: onlyBand, sampleRate: sampleRate)
            .maximumGainDecibels
        let toneAlone = FrequencyResponse(parameters: onlyTone, sampleRate: sampleRate)
            .maximumGainDecibels

        Check.close(
            combined, bandAlone + toneAlone, tolerance: 0.1,
            "the combined peak is the sum of two shelves reinforcing at the same frequency"
        )
        Check.isTrue(
            combined > bandAlone && combined > toneAlone,
            "and so exceeds either contributor alone"
        )

        // Preamp trim is not something headroom compensation should fight —
        // it is the manual tool for exactly this job.
        var trimmed = parameters
        trimmed.preampDecibels = -6
        let trimmedPeak = FrequencyResponse(parameters: trimmed, sampleRate: sampleRate)
            .maximumGainDecibels
        Check.close(
            trimmedPeak, combined, tolerance: 0.0001,
            "preamp trim does not change what headroom compensation sees"
        )

        // A chain with only cuts has no positive peak to compensate for.
        var onlyCuts = DSPParameters.flat
        onlyCuts.bandGains[4] = -8
        let cutPeak = FrequencyResponse(parameters: onlyCuts, sampleRate: sampleRate)
            .maximumGainDecibels
        Check.isTrue(
            cutPeak <= 0.0001,
            "an all-cut chain has nothing worth subtracting for"
        )
    }

    Check.suite("FrequencyResponse — volume alone is not in the curve") {
        // Volume is an attenuator, not a shape. With boost off, moving it
        // must not move the curve at all — otherwise the plot slides off the
        // display every time someone turns the music down.
        var loud = DSPParameters.flat
        loud.volume = 1
        var soft = DSPParameters.flat
        soft.volume = 0.2

        for probe in [30.0, 1000.0, 12_000.0] {
            Check.close(
                response(soft, at: probe), response(loud, at: probe),
                tolerance: 0.000_001,
                "volume does not tilt the curve at \(Int(probe)) Hz"
            )
        }
    }

    Check.suite("FrequencyResponse — evaluated from the compiled sections") {
        // The claim that makes the display trustworthy: the curve is drawn from
        // the same coefficients the audio thread is running. Compile a block
        // the way the publisher does and compare it against the list the sweep
        // was built from.
        var parameters = DSPParameters.flat
        parameters.bandGains = [3, -4, 0, 6, -12, 12, 2, -2, 9, -9]
        parameters.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels
        parameters.toneBassDecibels = 5
        parameters.toneTrebleDecibels = -5
        parameters.volume = 0.4
        parameters.preampDecibels = -3

        let designed = DSPChain.sections(for: parameters, sampleRate: sampleRate)
        Check.equal(designed.count, DSPChain.sectionCount, "one entry per section")

        let block = UnsafeMutablePointer<DSPBlock>.allocate(capacity: 1)
        block.initialize(to: DSPBlock())
        defer {
            block.deinitialize(count: 1)
            block.deallocate()
        }
        block.compile(from: parameters, sampleRate: sampleRate)

        var identical = true
        let compiled = block.sectionsBuffer
        for index in 0..<DSPChain.sectionCount where compiled[index] != designed[index] {
            identical = false
        }
        Check.isTrue(identical, "the compiled block holds exactly the swept sections")
    }

    Check.suite("FrequencyResponse — safe at every rate") {
        var parameters = DSPParameters.flat
        parameters.bandGains = Array(repeating: EQBank.maximumGainDecibels, count: 10)
        parameters.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels
        parameters.toneBassDecibels = DSPParameters.toneMaximumDecibels
        parameters.toneTrebleDecibels = -DSPParameters.toneMaximumDecibels
        parameters.volume = 0.1
        parameters.preampDecibels = -EQBank.maximumGainDecibels

        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let curve = FrequencyResponse(parameters: parameters, sampleRate: rate)
            let magnitudes = curve.magnitudeResponse(
                at: FrequencyResponse.logSpacedFrequencies(count: 120)
            )
            var allFinite = true
            for magnitude in magnitudes where !magnitude.isFinite { allFinite = false }
            Check.isTrue(allFinite, "every point is finite at \(Int(rate)) Hz")
        }

        // A stopped engine reports no rate at all. The curve still has to draw.
        let stopped = FrequencyResponse(parameters: parameters, sampleRate: 0)
        Check.equal(
            stopped.sampleRate, FrequencyResponse.nominalSampleRate,
            "no rate falls back to the nominal one"
        )
        Check.isTrue(
            stopped.magnitudeResponse(at: [1000])[0].isFinite,
            "and still produces a finite curve"
        )
    }

    Check.suite("FrequencyResponse — the logarithmic axis") {
        let frequencies = FrequencyResponse.logSpacedFrequencies(count: 120)
        Check.equal(frequencies.count, 120, "asked for 120, got 120")
        Check.close(frequencies[0], 20, tolerance: 0.000_001, "starts at 20 Hz")
        Check.close(frequencies[119], 20_000, tolerance: 0.000_1, "ends at 20 kHz")

        // Evenly spaced on a log axis means a constant *ratio* between
        // neighbours, not a constant difference.
        let firstRatio = frequencies[1] / frequencies[0]
        var worst = 0.0
        for index in 1..<frequencies.count {
            worst = max(worst, abs(frequencies[index] / frequencies[index - 1] - firstRatio))
        }
        Check.close(worst, 0, tolerance: 0.000_001, "every step is the same ratio")

        Check.close(
            FrequencyResponse.axisPosition(of: 20), 0, tolerance: 0.000_001,
            "20 Hz is the left edge"
        )
        Check.close(
            FrequencyResponse.axisPosition(of: 20_000), 1, tolerance: 0.000_001,
            "20 kHz is the right edge"
        )
        // Three decades across the axis, so one decade up is a third of the way.
        Check.close(
            FrequencyResponse.axisPosition(of: 200), 1.0 / 3, tolerance: 0.000_001,
            "a decade is a third of the width"
        )
        Check.close(
            FrequencyResponse.axisPosition(of: 2000), 2.0 / 3, tolerance: 0.000_001,
            "and two decades are two thirds"
        )

        // Degenerate requests produce nothing rather than a crash or a curve
        // with one point in it.
        Check.equal(
            FrequencyResponse.logSpacedFrequencies(count: 1).count, 0,
            "a single point is not an axis"
        )
        Check.equal(
            FrequencyResponse.logSpacedFrequencies(count: 10, from: 100, to: 100).count, 0,
            "a zero-width range is not an axis"
        )
    }

    // The sweep multiplies squared magnitudes and takes one logarithm per
    // point, rather than a square root and a logarithm per section per point.
    // That is an algebraic identity — `20·log₁₀(∏|H|) = 10·log₁₀(∏|H|²)` — and
    // this is what holds it to being one: the same curve, computed the slow,
    // obvious way, section by section.
    Check.suite("FrequencyResponse — the fast sweep matches the term-by-term one") {
        var parameters = DSPParameters.flat
        parameters.bandGains = [9, -7, 12, -12, 4, -3, 8, 0, 11, -6]
        parameters.toneBassDecibels = 10
        parameters.toneTrebleDecibels = -9
        parameters.boostDepthDecibels = 12
        parameters.preampDecibels = -5
        parameters.volume = 0.4

        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let normalised = parameters.normalised()
            let response = FrequencyResponse(parameters: parameters, sampleRate: rate)
            let sections = DSPChain.sections(for: normalised, sampleRate: rate)
            let frequencies = FrequencyResponse.logSpacedFrequencies(count: 120)
            let fast = response.magnitudeResponse(at: frequencies)

            var worst = 0.0
            for (index, frequency) in frequencies.enumerated() {
                // The term-by-term reference: one logarithm per section, added
                // up, exactly as the curve used to be computed.
                var reference = normalised.preampDecibels
                for section in sections {
                    reference += section.magnitudeDecibels(
                        atFrequency: frequency, sampleRate: rate
                    )
                }
                worst = max(worst, abs(fast[index] - reference))
            }
            Check.close(
                worst, 0, tolerance: 0.000_000_1,
                "\(Int(rate)) Hz — every point matches the term-by-term sum"
            )
        }
    }

    // `maximumGainDecibels` is what headroom compensation subtracts, and it is
    // now asked of a response the caller already built rather than of the
    // parameters — which used to build a second, identical one. Both entry
    // points must agree, or the cut applied to the audio and the figure shown
    // on screen come from different sweeps.
    Check.suite("FrequencyResponse — both headroom entry points agree") {
        var parameters = DSPParameters.flat
        parameters.bandGains = [6, 0, 9, 0, 3, 0, 7, 0, 11, 0]
        parameters.boostDepthDecibels = 9
        parameters.volume = 0.3

        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let viaParameters = parameters.headroomCompensationDecibels(sampleRate: rate)
            let viaResponse = FrequencyResponse(parameters: parameters, sampleRate: rate)
                .headroomCompensationDecibels(isEnabled: true)
            Check.close(
                viaResponse, viaParameters, tolerance: 0.000_000_1,
                "\(Int(rate)) Hz — the response and the parameters give the same cut"
            )
            Check.isTrue(viaParameters > 0, "\(Int(rate)) Hz — there is a cut to check")
        }

        // Defeated means zero from both, not "zero from one of them".
        var defeated = parameters
        defeated.isHeadroomCompensationEnabled = false
        Check.equal(
            defeated.headroomCompensationDecibels(sampleRate: 48_000), 0,
            "defeated compensation is no cut"
        )
        Check.equal(
            FrequencyResponse(parameters: defeated, sampleRate: 48_000)
                .headroomCompensationDecibels(isEnabled: false),
            0,
            "and the response agrees"
        )
    }
}

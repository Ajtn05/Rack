import AudioCore
import Darwin

/// Biquads are checked against their intended frequency response before they
/// go anywhere near the engine. Testing DSP by ear is slow and misleading: a
/// filter with the wrong Q, or one that is subtly unstable, sounds "a bit odd"
/// long before it sounds wrong, and by then it is buried under nine others.
func runBiquadTests() {
    let sampleRate = 48_000.0

    Check.suite("Biquad — peaking response") {
        for gain in [-12.0, -6.0, 6.0, 12.0] {
            let coefficients = BiquadCoefficients.peaking(
                frequency: 1000, q: EQBank.octaveQ,
                gainDecibels: gain, sampleRate: sampleRate
            )
            // The defining property: the requested gain, at the centre.
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 1000, sampleRate: sampleRate),
                gain, tolerance: 0.01,
                "peaking \(gain) dB hits its gain at the centre frequency"
            )
            // And leaves the rest of the spectrum alone.
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 20, sampleRate: sampleRate),
                0, tolerance: 0.3,
                "peaking \(gain) dB is flat four decades below"
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 20_000, sampleRate: sampleRate),
                0, tolerance: 0.5,
                "peaking \(gain) dB is flat well above"
            )
            Check.isTrue(coefficients.isStable, "peaking \(gain) dB is stable")
        }
    }

    Check.suite("Biquad — peaking bandwidth") {
        // One octave of bandwidth means the half-gain points land an octave
        // apart. If Q is wrong the bands overlap and a flat-looking set of
        // sliders produces a lumpy response.
        let coefficients = BiquadCoefficients.peaking(
            frequency: 1000, q: EQBank.octaveQ,
            gainDecibels: 12, sampleRate: sampleRate
        )
        Check.close(
            coefficients.magnitudeDecibels(atFrequency: 707, sampleRate: sampleRate),
            6, tolerance: 0.6,
            "half gain half an octave below centre"
        )
        Check.close(
            coefficients.magnitudeDecibels(atFrequency: 1414, sampleRate: sampleRate),
            6, tolerance: 0.6,
            "half gain half an octave above centre"
        )
    }

    Check.suite("Biquad — low shelf response") {
        for gain in [-12.0, 12.0] {
            let coefficients = BiquadCoefficients.lowShelf(
                frequency: 100, gainDecibels: gain, sampleRate: sampleRate
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 1, sampleRate: sampleRate),
                gain, tolerance: 0.2,
                "low shelf \(gain) dB reaches full gain at DC"
            )
            // Half the gain at the corner is what makes it a shelf rather
            // than a step.
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 100, sampleRate: sampleRate),
                gain / 2, tolerance: 0.2,
                "low shelf \(gain) dB is at half gain on the corner"
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 10_000, sampleRate: sampleRate),
                0, tolerance: 0.2,
                "low shelf \(gain) dB leaves the treble alone"
            )
            Check.isTrue(coefficients.isStable, "low shelf \(gain) dB is stable")
        }
    }

    Check.suite("Biquad — high shelf response") {
        for gain in [-12.0, 12.0] {
            let coefficients = BiquadCoefficients.highShelf(
                frequency: 8000, gainDecibels: gain, sampleRate: sampleRate
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 23_000, sampleRate: sampleRate),
                gain, tolerance: 0.5,
                "high shelf \(gain) dB reaches full gain near Nyquist"
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 8000, sampleRate: sampleRate),
                gain / 2, tolerance: 0.3,
                "high shelf \(gain) dB is at half gain on the corner"
            )
            Check.close(
                coefficients.magnitudeDecibels(atFrequency: 50, sampleRate: sampleRate),
                0, tolerance: 0.2,
                "high shelf \(gain) dB leaves the bass alone"
            )
            Check.isTrue(coefficients.isStable, "high shelf \(gain) dB is stable")
        }
    }

    Check.suite("Biquad — zero gain is exactly identity") {
        // Not "close to identity". The null test in Phase 2 asks for
        // bit-identical output, and that only holds if a flat band is
        // literally y = x.
        let flat = BiquadCoefficients.peaking(
            frequency: 1000, q: EQBank.octaveQ, gainDecibels: 0, sampleRate: sampleRate
        )
        Check.isTrue(flat == .identity, "a 0 dB peaking band is the identity")
        Check.isTrue(
            BiquadCoefficients.lowShelf(
                frequency: 100, gainDecibels: 0, sampleRate: sampleRate
            ) == .identity,
            "a 0 dB low shelf is the identity"
        )
        Check.isTrue(
            BiquadCoefficients.highShelf(
                frequency: 8000, gainDecibels: 0, sampleRate: sampleRate
            ) == .identity,
            "a 0 dB high shelf is the identity"
        )

        var filter = Biquad(coefficients: .identity)
        var identical = true
        for i in 0..<512 {
            let input = Float(sin(Double(i) * 0.1)) * 0.7
            if filter.process(input) != input { identical = false }
        }
        Check.isTrue(identical, "the identity biquad is bit-transparent")
    }

    Check.suite("Biquad — every band at every rate") {
        // 44.1 kHz is the case that bites: the 16 kHz band sits close enough
        // to Nyquist that a naive design produces garbage or instability.
        for sampleRate in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0] {
            for (index, frequency) in EQBank.frequencies.enumerated() {
                for gain in [-EQBank.maximumGainDecibels, EQBank.maximumGainDecibels] {
                    let coefficients = EQBank.coefficients(
                        forBand: index, gainDecibels: gain, sampleRate: sampleRate
                    )
                    Check.isTrue(
                        coefficients.isFinite,
                        "band \(frequency) Hz at \(Int(sampleRate)) Hz is finite"
                    )
                    Check.isTrue(
                        coefficients.isStable,
                        "band \(frequency) Hz at \(Int(sampleRate)) Hz is stable"
                    )
                }
            }
        }
    }

    Check.suite("Biquad — bands above Nyquist degrade to identity") {
        // At 44.1 kHz the 16 kHz band is realisable; at a hypothetical low
        // rate it would not be, and it must go flat rather than explode.
        let coefficients = BiquadCoefficients.peaking(
            frequency: 16_000, q: EQBank.octaveQ,
            gainDecibels: 12, sampleRate: 22_050
        )
        Check.isTrue(
            coefficients == .identity,
            "a band at or above Nyquist falls back to the identity"
        )
    }

    Check.suite("Biquad — filters settle rather than ring forever") {
        // An impulse through an unstable filter grows without bound. This
        // catches a sign error in the denominator that the stability triangle
        // might not.
        var filter = Biquad(
            coefficients: .peaking(
                frequency: 31.25, q: EQBank.octaveQ,
                gainDecibels: 12, sampleRate: 48_000
            )
        )
        var peak: Float = 0
        _ = filter.process(1)
        for _ in 0..<48_000 {
            peak = max(peak, abs(filter.process(0)))
        }
        Check.isTrue(peak < 1, "the impulse response decays")

        var tail: Float = 0
        for _ in 0..<48_000 {
            tail = max(tail, abs(filter.process(0)))
        }
        Check.isTrue(tail < 0.001, "and has effectively died after two seconds")
    }
}

import Darwin

@testable import AudioCore

/// The Sound Field Processor's own maths: preset design, the coefficients
/// compiled from it, and — the one the brief calls out by name — whether
/// each preset's impulse response actually decays at the RT60 it claims.
func runReverbTests() {
    let sampleRate = 48_000.0

    Check.suite("ReverbPreset — latency is exactly the pre-delay") {
        for preset in ReverbPreset.allCases {
            Check.close(
                preset.latencyMilliseconds, preset.design.preDelayMilliseconds, tolerance: 0.0001,
                "\(preset.displayName)'s reported latency is its pre-delay and nothing else"
            )
        }
    }

    Check.suite("ReverbCoefficients — wet/dry mix") {
        let enabled = ReverbCoefficients.compile(
            preset: .hall, wetAmount: 0.5, isEnabled: true, sampleRate: sampleRate
        )
        Check.close(
            Double(enabled.wetGain * enabled.wetGain + enabled.dryGain * enabled.dryGain),
            1, tolerance: 0.001,
            "equal-power wet and dry gains sum to unity power"
        )
        Check.isTrue(enabled.wetGain > 0 && enabled.dryGain > 0, "50% wet mixes both")

        let disabled = ReverbCoefficients.compile(
            preset: .hall, wetAmount: 0.8, isEnabled: false, sampleRate: sampleRate
        )
        Check.close(
            Double(disabled.wetGain), 0, tolerance: 0.0001,
            "disabled means no wet, whatever the mix knob is set to"
        )
        Check.close(Double(disabled.dryGain), 1, tolerance: 0.0001, "and full dry")

        let zeroWet = ReverbCoefficients.compile(
            preset: .hall, wetAmount: 0, isEnabled: true, sampleRate: sampleRate
        )
        Check.close(
            Double(zeroWet.wetGain), 0, tolerance: 0.0001,
            "0% wet is silent even while enabled — the two defaults agree"
        )
    }

    Check.suite("Reverb — every preset's lines and pre-delay fit their buffers") {
        // At the worst sample rate the buffers are sized for, since that is
        // exactly the case a real device could ask for.
        for preset in ReverbPreset.allCases {
            let coefficients = ReverbCoefficients.compile(
                preset: preset, wetAmount: 1, isEnabled: true,
                sampleRate: Reverb.maximumSampleRate
            )
            let leftLengths = [
                coefficients.lineSamplesLeft.0, coefficients.lineSamplesLeft.1,
                coefficients.lineSamplesLeft.2, coefficients.lineSamplesLeft.3,
            ]
            let rightLengths = [
                coefficients.lineSamplesRight.0, coefficients.lineSamplesRight.1,
                coefficients.lineSamplesRight.2, coefficients.lineSamplesRight.3,
            ]
            for (index, length) in leftLengths.enumerated() {
                Check.isTrue(
                    length > 0 && Int(length) <= Reverb.maximumLineSamples(forLine: index),
                    "\(preset.displayName) left line \(index) fits its allocated capacity"
                )
            }
            for (index, length) in rightLengths.enumerated() {
                Check.isTrue(
                    length > 0 && Int(length) <= Reverb.maximumLineSamples(forLine: index),
                    "\(preset.displayName) right line \(index) fits its allocated capacity"
                )
            }
            Check.isTrue(
                coefficients.preDelaySamples > 0
                    && Int(coefficients.preDelaySamples) <= Reverb.maximumPreDelaySamples(),
                "\(preset.displayName)'s pre-delay fits its allocated capacity"
            )
        }

        // And at a sample rate above the design ceiling, which must clamp
        // rather than overrun.
        let extreme = ReverbCoefficients.compile(
            preset: .stadium, wetAmount: 1, isEnabled: true, sampleRate: 768_000
        )
        Check.isTrue(
            Int(extreme.lineSamplesLeft.3) <= Reverb.maximumLineSamples(forLine: 3),
            "a rate above the design ceiling clamps rather than overruns the buffer"
        )
    }

    Check.suite("Reverb — the tail decays at the preset's own RT60") {
        for preset in ReverbPreset.allCases {
            var voice = ReverbVoiceState.allocate()
            defer { voice.free() }

            let coefficients = ReverbCoefficients.compile(
                preset: preset, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
            )
            voice.reconfigure(to: coefficients)

            let decaySeconds = preset.design.decaySeconds

            // A low tone, not an impulse: `decaySeconds` is the decay every
            // preset's damping is defined *relative to* — the rate low
            // frequencies decay at, which damping then shortens for the
            // high end on top of. A broadband impulse's first cycles are
            // mostly high-frequency content, which damping (by design)
            // decays several times faster than this, so measuring from one
            // reads every preset as decaying roughly twice too fast — that
            // is the damping working, not the decay gain being wrong. At
            // 120 Hz the heaviest damping any preset uses (Jazz Club, 0.50)
            // still passes better than 99.9% of the signal, so this
            // isolates the number `feedbackGain` was actually designed to
            // hit.
            let toneFrequency = 120.0
            // Long enough to clear pre-delay and drive the network to a
            // settled level before the decay is measured from it.
            let burstSeconds = max(preset.design.preDelayMilliseconds / 1000 + 0.05, 0.3)
            let burstSamples = Int(burstSeconds * sampleRate)
            // Generous margin past the expected decay, so a preset that
            // runs a little long is measured rather than cut off mid-tail.
            let sampleCount = burstSamples + Int(decaySeconds * 1.4 * sampleRate)

            // A twenty-millisecond envelope follower — several periods of
            // the tone, so the envelope tracks the decay rather than
            // rippling at the tone's own frequency.
            let releaseFrames = Float(max(Int(0.02 * sampleRate), 1))
            var envelope: Float = 0
            var trace: [Float] = []
            trace.reserveCapacity(sampleCount)

            for sample in 0..<sampleCount {
                let input: Float = sample < burstSamples
                    ? Float(sin(2 * .pi * toneFrequency * Double(sample) / sampleRate))
                    : 0
                let (wetLeft, _) = voice.process(inputLeft: input, inputRight: input)
                envelope = max(abs(wetLeft), envelope - envelope / releaseFrames)
                trace.append(envelope)
            }

            guard let peak = trace.max(), peak > 0,
                  let peakIndex = trace.firstIndex(of: peak)
            else {
                Check.isTrue(false, "\(preset.displayName) produced no tail at all")
                continue
            }

            // T30: the standard acoustic measurement for exactly this
            // situation. An FDN's early reflections recirculate and build
            // before the tail settles into its true exponential decay, so
            // the response's own peak sits above the level a plain
            // "60 dB down from the impulse" count would start from — measured
            // from there, the crossing arrives early and the network reads as
            // decaying roughly twice as fast as it was designed to. Measuring
            // the slope of a clean 30 dB window well after that peak, then
            // doubling it to reach 60 dB, is what a real reverb's RT60 is
            // measured this way for: it never touches the buildup transient.
            let dbTrace = trace.map { value -> Float in
                guard value > 0 else { return -.infinity }
                return 20 * log10(value / peak)
            }
            guard let start = dbTrace[peakIndex...].firstIndex(where: { $0 <= -5 }),
                  let end = dbTrace[peakIndex...].firstIndex(where: { $0 <= -35 }),
                  end > start
            else {
                Check.isTrue(
                    false,
                    "\(preset.displayName) never established a clean 30 dB decay slope"
                )
                continue
            }

            let measuredSeconds = 2 * Double(end - start) / sampleRate
            Check.close(
                measuredSeconds, decaySeconds, tolerance: decaySeconds * 0.35,
                "\(preset.displayName) decays 60 dB in roughly its stated RT60, by T30 "
                    + "(\(measuredSeconds)s measured vs \(decaySeconds)s designed)"
            )
        }
    }

    Check.suite("Reverb — damping shortens the tail's high end") {
        // Feed a bright impulse (a broadband click already exercises this,
        // but a stereo-summed high tone isolates it) and confirm heavier
        // damping settles faster than lighter damping at the same decay time.
        // Jazz Club (damping 0.50) against Live (damping 0.40) at nearby
        // decay times isolates the damping difference rather than the RT60
        // difference.
        func settleSamples(_ preset: ReverbPreset) -> Int {
            var voice = ReverbVoiceState.allocate()
            defer { voice.free() }
            let coefficients = ReverbCoefficients.compile(
                preset: preset, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
            )
            voice.reconfigure(to: coefficients)

            var envelope: Float = 0
            let releaseFrames = Float(max(Int(0.002 * sampleRate), 1))
            var peak: Float = 0
            var lastAbovePeakTenth = 0
            let sampleCount = Int(2 * sampleRate)
            for sample in 0..<sampleCount {
                // A short burst of an 8 kHz tone — high enough that damping,
                // not the overall RT60, dominates how fast it settles.
                let input: Float = sample < 200 ? Float(sin(2 * .pi * 8000 * Double(sample) / sampleRate)) : 0
                let (wetLeft, _) = voice.process(inputLeft: input, inputRight: input)
                envelope = max(abs(wetLeft), envelope - envelope / releaseFrames)
                peak = max(peak, envelope)
                if peak > 0, envelope > peak * 0.1 { lastAbovePeakTenth = sample }
            }
            return lastAbovePeakTenth
        }

        let jazzClub = settleSamples(.jazzClub)
        let live = settleSamples(.live)
        Check.isTrue(
            jazzClub < live,
            "the more heavily damped preset settles its high end sooner "
                + "(jazz club \(jazzClub) vs live \(live) samples)"
        )
    }
}

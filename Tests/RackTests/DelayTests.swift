import Darwin

@testable import AudioCore

/// The Sound Field Processor's echo, alongside `ReverbTests` for its
/// reverb: preset design, the coefficients compiled from it, and — the
/// property that actually distinguishes an echo from a reverb — whether an
/// impulse produces a *discrete, countable* repeat at the preset's own time
/// rather than a diffuse wash.
func runDelayTests() {
    let sampleRate = 48_000.0

    Check.suite("DelayPreset — the readout is the left line's own time") {
        for preset in DelayPreset.allCases {
            Check.close(
                preset.timeMilliseconds, preset.design.leftDelayMilliseconds, tolerance: 0.0001,
                "\(preset.displayName)'s reported time is its left line and nothing else"
            )
        }
    }

    Check.suite("DelayCoefficients — wet/dry mix") {
        let enabled = DelayCoefficients.compile(
            preset: .echo, wetAmount: 0.5, isEnabled: true, sampleRate: sampleRate
        )
        Check.close(
            Double(enabled.wetGain * enabled.wetGain + enabled.dryGain * enabled.dryGain),
            1, tolerance: 0.001,
            "equal-power wet and dry gains sum to unity power"
        )
        Check.isTrue(enabled.wetGain > 0 && enabled.dryGain > 0, "50% wet mixes both")

        let disabled = DelayCoefficients.compile(
            preset: .echo, wetAmount: 0.8, isEnabled: false, sampleRate: sampleRate
        )
        Check.close(
            Double(disabled.wetGain), 0, tolerance: 0.0001,
            "disabled means no wet, whatever the mix knob is set to"
        )
        Check.close(Double(disabled.dryGain), 1, tolerance: 0.0001, "and full dry")
    }

    Check.suite("Delay — every preset's lines fit their buffers") {
        for preset in DelayPreset.allCases {
            let coefficients = DelayCoefficients.compile(
                preset: preset, wetAmount: 1, isEnabled: true, sampleRate: Delay.maximumSampleRate
            )
            Check.isTrue(
                coefficients.leftLineSamples > 0
                    && Int(coefficients.leftLineSamples) <= Delay.maximumLineSamples(),
                "\(preset.displayName)'s left line fits its allocated capacity"
            )
            Check.isTrue(
                coefficients.rightLineSamples > 0
                    && Int(coefficients.rightLineSamples) <= Delay.maximumLineSamples(),
                "\(preset.displayName)'s right line fits its allocated capacity"
            )
        }

        // Above the design ceiling, which must clamp rather than overrun.
        let extreme = DelayCoefficients.compile(
            preset: .dub, wetAmount: 1, isEnabled: true, sampleRate: 768_000
        )
        Check.isTrue(
            Int(extreme.leftLineSamples) <= Delay.maximumLineSamples(),
            "a rate above the design ceiling clamps rather than overruns the buffer"
        )
    }

    Check.suite("Delay — Ping-Pong runs different times per channel") {
        let design = DelayPreset.pingPong.design
        Check.isTrue(
            design.leftDelayMilliseconds != design.rightDelayMilliseconds,
            "the whole character of Ping-Pong is the two channels landing at different moments"
        )
        // Every other preset keeps both channels together.
        for preset in DelayPreset.allCases where preset != .pingPong {
            Check.close(
                preset.design.leftDelayMilliseconds, preset.design.rightDelayMilliseconds,
                tolerance: 0.0001, "\(preset.displayName) is not a ping-pong preset"
            )
        }
    }

    Check.suite("Delay — an impulse produces a repeat at the preset's own time") {
        for preset in [DelayPreset.slapback, .echo, .dub] {
            var voice = DelayVoiceState.allocate()
            defer { voice.free() }
            let coefficients = DelayCoefficients.compile(
                preset: preset, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
            )
            voice.reconfigure(to: coefficients)

            let expectedSample = Int(preset.design.leftDelayMilliseconds / 1000 * sampleRate)
            var trace: [Float] = []
            trace.reserveCapacity(expectedSample + 100)

            for sample in 0...(expectedSample + 50) {
                let input: Float = sample == 0 ? 1 : 0
                let (wetLeft, _) = voice.process(inputLeft: input, inputRight: input)
                trace.append(wetLeft)
            }

            guard let peakIndex = trace.indices.max(by: { trace[$0] < trace[$1] }) else {
                Check.isTrue(false, "\(preset.displayName) produced no repeat at all")
                continue
            }
            Check.isTrue(
                abs(peakIndex - expectedSample) <= 1,
                "\(preset.displayName)'s repeat lands within a sample of its own delay time "
                    + "(expected \(expectedSample), measured \(peakIndex))"
            )
        }
    }

    Check.suite("Delay — feedback produces further repeats that decay") {
        // Echo has real feedback (0.35): a second repeat should exist near
        // twice the delay time, quieter than the first.
        var voice = DelayVoiceState.allocate()
        defer { voice.free() }
        let coefficients = DelayCoefficients.compile(
            preset: .echo, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )
        voice.reconfigure(to: coefficients)

        let delaySamples = Int(DelayPreset.echo.design.leftDelayMilliseconds / 1000 * sampleRate)
        var trace: [Float] = []
        let totalSamples = delaySamples * 3
        trace.reserveCapacity(totalSamples)
        for sample in 0..<totalSamples {
            let input: Float = sample == 0 ? 1 : 0
            let (wetLeft, _) = voice.process(inputLeft: input, inputRight: input)
            trace.append(abs(wetLeft))
        }

        let firstWindow = trace[(delaySamples - 5)...(delaySamples + 5)]
        let secondWindow = trace[(2 * delaySamples - 5)...(2 * delaySamples + 5)]
        let firstPeak = firstWindow.max() ?? 0
        let secondPeak = secondWindow.max() ?? 0

        Check.isTrue(firstPeak > 0.01, "the first repeat is clearly present")
        Check.isTrue(secondPeak > 0.01, "and a second repeat follows it")
        Check.isTrue(
            secondPeak < firstPeak,
            "each repeat is quieter than the last (first \(firstPeak), second \(secondPeak))"
        )
    }

    Check.suite("Delay — zero feedback produces exactly one repeat") {
        // Slapback's whole character: a single slap, nothing after it.
        var voice = DelayVoiceState.allocate()
        defer { voice.free() }
        let coefficients = DelayCoefficients.compile(
            preset: .slapback, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )
        voice.reconfigure(to: coefficients)

        let delaySamples = Int(DelayPreset.slapback.design.leftDelayMilliseconds / 1000 * sampleRate)
        var trace: [Float] = []
        let totalSamples = delaySamples * 3
        for sample in 0..<totalSamples {
            let input: Float = sample == 0 ? 1 : 0
            let (wetLeft, _) = voice.process(inputLeft: input, inputRight: input)
            trace.append(abs(wetLeft))
        }

        let secondWindow = trace[(2 * delaySamples - 5)...(2 * delaySamples + 5)]
        Check.isTrue(
            (secondWindow.max() ?? 0) < 0.0001,
            "with zero feedback nothing recirculates, so there is no second repeat at all"
        )
    }

    Check.suite("DelayEngine — crossfade settles to full weight and stays continuous") {
        var engine = DelayEngine.allocate()
        defer { engine.free() }
        let crossfade = Delay.crossfadeCoefficient(forSampleRate: sampleRate)
        let echo = DelayCoefficients.compile(
            preset: .echo, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )

        for _ in 0..<Int(sampleRate * 0.5) {
            _ = engine.process(
                inputLeft: 0, inputRight: 0, coefficients: echo, crossfadeCoefficient: crossfade
            )
        }
        Check.close(Double(engine.crossfadeGain), 1, tolerance: 0.001, "settles to full weight")

        let dub = DelayCoefficients.compile(
            preset: .dub, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )
        var weights: [Float] = []
        for _ in 0..<Int(sampleRate * Delay.crossfadeSeconds * 8) {
            let (left, right) = engine.process(
                inputLeft: 0, inputRight: 0, coefficients: dub, crossfadeCoefficient: crossfade
            )
            Check.isTrue(left.isFinite && right.isFinite, "every sample through a switch stays finite")
            weights.append(engine.crossfadeGain)
        }
        Check.isTrue(
            weights.last.map { $0 > 0.99 } ?? false,
            "the crossfade completes back to full weight on the new preset"
        )

        var monotonic = true
        for index in 1..<weights.count where weights[index] < weights[index - 1] - 0.0001 {
            monotonic = false
        }
        Check.isTrue(monotonic, "weight ramps smoothly toward the new target rather than jumping")
    }

    Check.suite("DelayEngine — a switch mid-crossfade waits rather than interrupting") {
        var engine = DelayEngine.allocate()
        defer { engine.free() }
        let crossfade = Delay.crossfadeCoefficient(forSampleRate: sampleRate)
        let echo = DelayCoefficients.compile(
            preset: .echo, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )
        let dub = DelayCoefficients.compile(
            preset: .dub, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )
        let pingPong = DelayCoefficients.compile(
            preset: .pingPong, wetAmount: 1, isEnabled: true, sampleRate: sampleRate
        )

        for _ in 0..<Int(sampleRate * 0.5) {
            _ = engine.process(
                inputLeft: 0, inputRight: 0, coefficients: echo, crossfadeCoefficient: crossfade
            )
        }

        // Switch to dub, then immediately request ping-pong before the fade
        // to dub has any real chance to finish (it takes ~50 ms; two samples
        // is nowhere near that).
        _ = engine.process(
            inputLeft: 0, inputRight: 0, coefficients: dub, crossfadeCoefficient: crossfade
        )
        _ = engine.process(
            inputLeft: 0, inputRight: 0, coefficients: pingPong, crossfadeCoefficient: crossfade
        )

        let currentTarget = engine.targetIsA ? engine.voiceA.currentPresetIndex : engine.voiceB.currentPresetIndex
        Check.equal(
            currentTarget, dub.presetIndex,
            "the still-in-flight switch to dub is not preempted by the ping-pong request"
        )

        // Let the fade to dub finish, then the deferred switch should go
        // through on the next request.
        for _ in 0..<Int(sampleRate * Delay.crossfadeSeconds * 8) {
            _ = engine.process(
                inputLeft: 0, inputRight: 0, coefficients: dub, crossfadeCoefficient: crossfade
            )
        }
        _ = engine.process(
            inputLeft: 0, inputRight: 0, coefficients: pingPong, crossfadeCoefficient: crossfade
        )
        let afterTarget = engine.targetIsA ? engine.voiceA.currentPresetIndex : engine.voiceB.currentPresetIndex
        Check.equal(afterTarget, pingPong.presetIndex, "once dub settles, the deferred request goes through")
    }
}

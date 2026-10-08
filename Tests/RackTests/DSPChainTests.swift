import Darwin
import Dispatch

@testable import AudioCore

// One writer and one reader, joined before the publisher can be freed.
private final class ExchangeStressFixture: @unchecked Sendable {
    let publisher = ParameterPublisher()
}

/// The chain as the audio thread actually runs it: real published blocks, real
/// filter state, real gain smoothing.
func runDSPChainTests() {
    let sampleRate = 48_000.0

    Check.suite("DSPBlock — memory layout") {
        // Both `sectionsBuffer` and `filtersBuffer` reinterpret a pointer to
        // the struct as a pointer to its first field. If anything is ever
        // inserted above `sections`, the audio thread starts reading gains as
        // coefficients and the failure is spectacular. Assert it instead.
        Check.equal(
            MemoryLayout<DSPBlock>.offset(of: \.sections), 0,
            "DSPBlock.sections is the first field"
        )
        Check.equal(
            MemoryLayout<DSPRenderState.ChannelFilters>.offset(of: \.sections), 0,
            "ChannelFilters.sections is the first field"
        )
    }

    Check.suite("ParameterPublisher — publication") {
        let publisher = ParameterPublisher()

        var parameters = DSPParameters.flat
        parameters.preampDecibels = -6
        publisher.publish(parameters, sampleRate: sampleRate)

        var block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        Check.close(
            Double(block.pointee.outputGain), 0.501187, tolerance: 0.0001,
            "the reader sees what was published"
        )

        // Nothing new published: the reader must keep the block it holds
        // rather than swapping itself back to a stale slot.
        block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        Check.close(
            Double(block.pointee.outputGain), 0.501187, tolerance: 0.0001,
            "an acquire with nothing new keeps the current block"
        )

        // Several publications between reads: the newest wins and the skipped
        // ones are simply skipped, which is correct for parameters.
        for decibels in [-3.0, 0.0, 6.0] {
            parameters.preampDecibels = decibels
            publisher.publish(parameters, sampleRate: sampleRate)
        }
        block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        Check.close(
            Double(block.pointee.outputGain), 1.995262, tolerance: 0.0001,
            "the most recent publication wins"
        )
    }

    Check.suite("ParameterPublisher — concurrent publications never go backwards or tear") {
        let fixture = ExchangeStressFixture()
        let group = DispatchGroup()
        let publications = 50_000
        DispatchQueue.global().async(group: group) {
            for sequence in 1...publications {
                fixture.publisher.publish(
                    .flat, streamGains: [Float(sequence), Float(sequence)], sampleRate: 48_000
                )
            }
        }
        var previous: Float = 0
        var monotonic = true
        var coherent = true
        repeat {
            let block = rackAcquireBlock(
                exchange: fixture.publisher.exchange, slots: fixture.publisher.slots
            )
            let left = block.pointee.streamGains.0
            let right = block.pointee.streamGains.1
            if left < previous { monotonic = false }
            if left != right { coherent = false }
            previous = left
        } while group.wait(timeout: .now()) != .success
        let latest = rackAcquireBlock(
            exchange: fixture.publisher.exchange, slots: fixture.publisher.slots
        )
        Check.isTrue(monotonic, "a reader never swaps back to an older publication")
        Check.isTrue(coherent, "a held slot is never overwritten by the writer")
        Check.equal(latest.pointee.streamGains.0, Float(publications), "the final publication arrives")
    }

    Check.suite("ParameterPublisher — cached design still updates gains, settings and rate") {
        let publisher = ParameterPublisher()
        var parameters = DSPParameters.flat
        parameters.bandGains[5] = 6
        publisher.publish(parameters, streamGains: [0.2], sampleRate: sampleRate)
        _ = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        publisher.publish(parameters, streamGains: [0.8], sampleRate: sampleRate)
        var block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        Check.equal(block.pointee.streamGains.0, 0.8, "faders update on a cached design")
        parameters.bandGains[5] = -6
        publisher.publish(parameters, sampleRate: 96_000)
        block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        Check.close(
            block.sectionsBuffer[DSPChain.eqSectionStart + 5].magnitudeDecibels(
                atFrequency: 1000, sampleRate: 96_000
            ), -6, tolerance: 0.01, "parameter and rate changes invalidate the design"
        )
        Check.equal(block.pointee.streamGains.0, 1, "omitted gains return to unity")
    }

    Check.suite("DSP chain — null test") {
        // Flat EQ, unity gain, centred balance, no boost. The output must be
        // *bit-identical* to the input, not merely close: every stage is
        // either an exact identity biquad or a multiply by exactly 1.0.
        let publisher = ParameterPublisher()
        publisher.publish(.flat, sampleRate: sampleRate)
        let block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)

        var state = DSPRenderState()
        state.smoothingCoefficient = DSPRenderState.smoothingCoefficient(
            forSampleRate: sampleRate
        )

        let frameCount = 4096
        var input = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            // Something with content across the spectrum, so a stray filter
            // would show up rather than hiding under a single tone.
            let t = Double(i) / sampleRate
            input[i] = Float(
                0.4 * sin(2 * .pi * 55 * t)
                    + 0.3 * sin(2 * .pi * 997 * t)
                    + 0.2 * sin(2 * .pi * 11_000 * t)
            )
        }
        var output = input

        output.withUnsafeMutableBufferPointer { buffer in
            withUnsafeMutablePointer(to: &state.left) { channel in
                rackProcessChannel(
                    samples: buffer.baseAddress!,
                    frameCount: frameCount,
                    stride: 1,
                    filters: channel.filtersBuffer,
                    coefficients: block.sectionsBuffer,
                    gain: &state.leftGain,
                    targetGain: block.pointee.outputGain * block.pointee.leftGain,
                    smoothing: state.smoothingCoefficient
                )
            }
        }

        var identical = true
        var worstDifference: Float = 0
        for i in 0..<frameCount where output[i] != input[i] {
            identical = false
            worstDifference = max(worstDifference, abs(output[i] - input[i]))
        }
        Check.isTrue(
            identical,
            "flat parameters are bit-transparent (worst difference \(worstDifference))"
        )
    }

    Check.suite("DSP chain — the EQ actually does something") {
        // The complement of the null test: a boosted band must show up, and
        // only where it was asked for.
        var parameters = DSPParameters.flat
        let bandIndex = 5  // 1 kHz
        parameters.bandGains[bandIndex] = 12

        let publisher = ParameterPublisher()
        publisher.publish(parameters, sampleRate: sampleRate)
        let block = rackAcquireBlock(exchange: publisher.exchange, slots: publisher.slots)
        let sections = block.sectionsBuffer

        // The EQ bands sit after the two tone shelves in the chain.
        let sectionIndex = DSPChain.eqSectionStart + bandIndex
        Check.close(
            sections[sectionIndex].magnitudeDecibels(
                atFrequency: EQBank.frequencies[bandIndex], sampleRate: sampleRate
            ),
            12, tolerance: 0.01,
            "the boosted band carries the boost"
        )
        for other in 0..<EQBank.bandCount where other != bandIndex {
            Check.isTrue(
                sections[DSPChain.eqSectionStart + other] == .identity,
                "band \(EQBank.frequencies[other]) Hz is untouched"
            )
        }
        Check.isTrue(
            sections[DSPChain.toneBassSection] == .identity
                && sections[DSPChain.toneTrebleSection] == .identity,
            "the tone shelves are untouched by an EQ band"
        )
        Check.isTrue(
            sections[DSPChain.boostBassSection] == .identity
                && sections[DSPChain.boostTrebleSection] == .identity,
            "and so are the boost shelves"
        )
    }

    Check.suite("DSP chain — balance") {
        var parameters = DSPParameters.flat

        parameters.balance = 0
        var gains = parameters.channelGains
        Check.close(gains.left, 1, tolerance: 0.0001, "centre leaves the left alone")
        Check.close(gains.right, 1, tolerance: 0.0001, "centre leaves the right alone")

        parameters.balance = -1
        gains = parameters.channelGains
        Check.close(gains.left, 1, tolerance: 0.0001, "hard left keeps the left at unity")
        Check.close(gains.right, 0, tolerance: 0.0001, "hard left silences the right")

        parameters.balance = 1
        gains = parameters.channelGains
        Check.close(gains.left, 0, tolerance: 0.0001, "hard right silences the left")
        Check.close(gains.right, 1, tolerance: 0.0001, "hard right keeps the right at unity")

        // Attenuating rather than boosting: panning must never push a track
        // that is already near full scale into clipping.
        parameters.balance = -0.5
        gains = parameters.channelGains
        Check.isTrue(gains.left <= 1 && gains.right <= 1, "balance never boosts")
    }

    Check.suite("DSP chain — boost contour") {
        var parameters = DSPParameters.flat
        parameters.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels  // 12

        // At full volume there is nothing to compensate for, and the contour
        // must be exactly zero or it would break the null test.
        parameters.volume = 1
        Check.close(
            parameters.boostBassDecibels, 0, tolerance: 0.0001,
            "no bass lift at full volume"
        )
        Check.close(
            parameters.boostTrebleDecibels, 0, tolerance: 0.0001,
            "no treble lift at full volume"
        )

        // The taper is dB-linear across 48 dB, so travel and decibels move
        // together — which is the whole reason a number beside the knob can be
        // trusted.
        parameters.volume = 0.5
        Check.close(
            parameters.volumeDecibels, -24, tolerance: 0.01,
            "half travel is half the range, in decibels"
        )
        // Past the compensation point the contour saturates rather than
        // continuing to grow.
        Check.close(
            parameters.volumeAttenuationDecibels,
            DSPParameters.boostFullCompensationDecibels, tolerance: 0.01,
            "and is far enough down to reach full compensation"
        )
        Check.close(
            parameters.boostBassDecibels,
            DSPParameters.boostMaximumDepthDecibels, tolerance: 0.05,
            "so the bass lift reaches the full depth the knob is set to"
        )

        // Somewhere in the normal listening range, where the contour should be
        // partial rather than saturated.
        parameters.volume = 0.8
        Check.close(
            parameters.volumeDecibels, -9.6, tolerance: 0.01,
            "a small reduction is a small number of decibels"
        )
        Check.close(
            parameters.boostBassDecibels, 7.68, tolerance: 0.05,
            "and gives a proportional lift — 9.6/15 of the 12 dB depth"
        )
        Check.isTrue(
            parameters.boostBassDecibels > parameters.boostTrebleDecibels,
            "the contour lifts bass more than treble"
        )

        // A modest reduction still produces something worth hearing.
        parameters.volume = 0.9
        Check.isTrue(
            parameters.boostBassDecibels > 3,
            "even a slight volume reduction gives an audible lift "
                + "(\(parameters.boostBassDecibels) dB)"
        )

        // Fully down, the contour saturates rather than running away.
        parameters.volume = 0
        Check.close(
            parameters.boostBassDecibels,
            DSPParameters.boostMaximumDepthDecibels, tolerance: 0.0001,
            "full bass lift once attenuation reaches the compensation point"
        )

        parameters.boostDepthDecibels = 0
        Check.close(
            parameters.boostBassDecibels, 0, tolerance: 0.0001,
            "depth zero means no contour at any volume"
        )
    }

    Check.suite("DSP chain — tone control") {
        var parameters = DSPParameters.flat
        parameters.toneBassDecibels = 6
        parameters.toneTrebleDecibels = -4

        Check.close(
            parameters.effectiveToneBassDecibels, 6, tolerance: 0.0001,
            "the bass shelf reaches the chain at its set gain"
        )
        Check.close(
            parameters.effectiveToneTrebleDecibels, -4, tolerance: 0.0001,
            "as does the treble shelf"
        )

        parameters.isToneDefeated = true
        Check.close(
            parameters.effectiveToneBassDecibels, 0, tolerance: 0.0001,
            "TONE DEFEAT bypasses the bass shelf"
        )
        Check.close(
            parameters.effectiveToneTrebleDecibels, 0, tolerance: 0.0001,
            "and the treble shelf"
        )
        Check.close(
            parameters.toneBassDecibels, 6, tolerance: 0.0001,
            "without zeroing the stored position"
        )
        Check.close(
            parameters.toneTrebleDecibels, -4, tolerance: 0.0001,
            "either knob"
        )
    }

    Check.suite("DSP chain — headroom compensation") {
        // A flat chain has nothing to compensate for.
        Check.close(
            DSPParameters.flat.headroomCompensationDecibels(sampleRate: sampleRate),
            0, tolerance: 0.0001,
            "no gain in the chain means no cut"
        )

        // Boost turned up, volume down far enough to reach full depth — the
        // case this exists for. The shelf's own gain and the cut it earns are
        // set by the same combined peak, so they very nearly cancel.
        var parameters = DSPParameters.flat
        parameters.volume = 0.5
        parameters.boostDepthDecibels = DSPParameters.boostMaximumDepthDecibels

        let headroom = parameters.headroomCompensationDecibels(sampleRate: sampleRate)
        Check.close(
            headroom, DSPParameters.boostMaximumDepthDecibels, tolerance: 0.2,
            "the cut matches the depth the boost shelf reaches"
        )

        let compensatedGain = parameters.outputGain * pow(10, -headroom / 20)
        Check.isTrue(
            compensatedGain <= parameters.outputGain + 0.0001,
            "the compensated output gain never exceeds the uncompensated one"
        )

        // Defeatable, for anyone who wants the raw gain.
        parameters.isHeadroomCompensationEnabled = false
        Check.close(
            parameters.headroomCompensationDecibels(sampleRate: sampleRate),
            0, tolerance: 0.0001,
            "defeated means no cut, whatever the chain is doing"
        )
    }

    Check.suite("DSP chain — gain smoothing") {
        // A gain change must ramp, not step. This is the difference between a
        // slider drag sounding smooth and sounding like tearing paper.
        var gain: Float = 1
        let coefficient = DSPRenderState.smoothingCoefficient(forSampleRate: sampleRate)
        let target: Float = 0.5

        gain = rackSmooth(gain, toward: target, coefficient: coefficient)
        Check.isTrue(gain < 1 && gain > 0.99, "one sample moves the gain barely at all")

        // A one-pole approaches its target exponentially and never quite
        // arrives: after n time constants e^-n of the step remains, so five
        // still leaves 0.67% — enough to fail a 0.001 tolerance. Ten leaves
        // 45 parts per million, which is inaudible and testable.
        for _ in 0..<Int(sampleRate * DSPRenderState.smoothingSeconds * 10) {
            gain = rackSmooth(gain, toward: target, coefficient: coefficient)
        }
        Check.close(Double(gain), 0.5, tolerance: 0.001, "and settles on the target")

        // An unchanged target must not drift, or the null test would fail.
        var steady: Float = 1
        for _ in 0..<10_000 {
            steady = rackSmooth(steady, toward: 1, coefficient: coefficient)
        }
        Check.isTrue(steady == 1, "a gain already at its target stays exactly there")
    }

    Check.suite("DSPParameters — normalisation") {
        var parameters = DSPParameters.flat
        parameters.preampDecibels = 500
        parameters.balance = -9
        parameters.boostDepthDecibels = 99
        parameters.toneBassDecibels = -99
        parameters.bandGains = [99, -99]  // wrong length as well as out of range

        let clean = parameters.normalised()
        Check.close(
            clean.preampDecibels, EQBank.maximumGainDecibels, tolerance: 0.0001,
            "preamp is clamped"
        )
        Check.close(clean.balance, -1, tolerance: 0.0001, "balance is clamped")
        Check.close(
            clean.boostDepthDecibels, DSPParameters.boostMaximumDepthDecibels, tolerance: 0.0001,
            "boost depth is clamped"
        )
        Check.close(
            clean.toneBassDecibels, -DSPParameters.toneMaximumDecibels, tolerance: 0.0001,
            "tone is clamped"
        )
        Check.equal(clean.bandGains.count, EQBank.bandCount, "band count is corrected")
        Check.close(
            clean.bandGains[0], EQBank.maximumGainDecibels, tolerance: 0.0001,
            "band gains are clamped"
        )
        Check.close(clean.bandGains[9], 0, tolerance: 0.0001, "missing bands default to flat")

        // A hand-edited preset file can contain anything at all.
        var broken = DSPParameters.flat
        broken.preampDecibels = .nan
        broken.bandGains[0] = .infinity
        let repaired = broken.normalised()
        Check.isTrue(repaired.preampDecibels.isFinite, "NaN is rejected, not propagated")
        Check.isTrue(repaired.bandGains[0].isFinite, "infinity is rejected too")
    }
}

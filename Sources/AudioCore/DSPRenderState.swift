import Darwin

/// Filter state and smoothed gains, owned exclusively by the audio thread.
///
/// Nothing else reads or writes this. Filter state is not shared: the UI
/// publishes *coefficients* and the delay lines stay here, which is what keeps
/// a slider drag from corrupting a filter mid-sample.
struct DSPRenderState {
    var left = ChannelFilters()
    var right = ChannelFilters()

    /// Crossfeed's own filters — not part of either channel's section
    /// cascade above, because each one shapes a signal that crosses between
    /// channels: `crossfeedLeftFilter` rolls off the left signal on its way
    /// to bleeding into the right ear, `crossfeedRightFilter` the mirror.
    var crossfeedLeftFilter = Biquad()
    var crossfeedRightFilter = Biquad()

    /// Gains are smoothed rather than applied instantly. A gain that steps
    /// once per buffer is a discontinuity every 256 samples, and a run of them
    /// is the zipper noise you hear when a badly written mixer's fader moves.
    var preampGain: Float = 1
    var leftGain: Float = 1
    var rightGain: Float = 1

    /// Smoothed per-stream gains, matching `DSPBlock.streamGains`. Ramped for
    /// the same reason the master gains are: an app's volume slider that steps
    /// per buffer is as audible as any other.
    var streamGains: StreamGainStorage = DSPRenderState.unityStreamGains

    typealias StreamGainStorage = (
        Float, Float, Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float, Float, Float
    )

    static let unityStreamGains: StreamGainStorage = (
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
    )

    /// One-pole coefficient, derived from the sample rate. Recomputed whenever
    /// the rate changes.
    var smoothingCoefficient: Float = DSPRenderState.smoothingCoefficient(forSampleRate: 48_000)

    /// Time constant for gain ramps. Fast enough to feel immediate, slow
    /// enough that the step is inaudible.
    static let smoothingSeconds: Double = 0.02

    static func smoothingCoefficient(forSampleRate sampleRate: Double) -> Float {
        guard sampleRate > 0 else { return 1 }
        return Float(1 - exp(-1 / (smoothingSeconds * sampleRate)))
    }

    /// Clear every delay line. Called when the signal is discontinuous — a
    /// device or sample rate change — because the state left behind belongs to
    /// a stream that no longer exists, and releasing it into the new one is an
    /// audible thump.
    mutating func reset() {
        left.reset()
        right.reset()
        crossfeedLeftFilter.reset()
        crossfeedRightFilter.reset()
    }

    struct ChannelFilters {
        /// Fourteen sections, matching `DSPBlock.SectionStorage`. First field,
        /// for the same pointer-aliasing reason.
        var sections: SectionStorage = ChannelFilters.emptySections

        typealias SectionStorage = (
            Biquad, Biquad, Biquad, Biquad, Biquad, Biquad,
            Biquad, Biquad, Biquad, Biquad, Biquad, Biquad,
            Biquad, Biquad
        )

        static let emptySections: SectionStorage = (
            Biquad(), Biquad(), Biquad(), Biquad(), Biquad(), Biquad(),
            Biquad(), Biquad(), Biquad(), Biquad(), Biquad(), Biquad(),
            Biquad(), Biquad()
        )

        mutating func reset() {
            withUnsafeMutablePointer(to: &self) { pointer in
                let filters = pointer.filtersBuffer
                for index in 0..<DSPChain.sectionCount {
                    filters[index].reset()
                }
            }
        }
    }
}

extension UnsafeMutablePointer<DSPRenderState> {
    /// The smoothed per-stream gains as a buffer.
    @inline(__always)
    var streamGainsBuffer: UnsafeMutableBufferPointer<Float> {
        let offset = MemoryLayout<DSPRenderState>.offset(of: \.streamGains) ?? 0
        return UnsafeMutableBufferPointer(
            start: UnsafeMutableRawPointer(self)
                .advanced(by: offset)
                .assumingMemoryBound(to: Float.self),
            count: DSPChain.maximumStreams
        )
    }
}

extension UnsafeMutablePointer<DSPRenderState.ChannelFilters> {
    /// Valid because `sections` is the first field.
    @inline(__always)
    var filtersBuffer: UnsafeMutableBufferPointer<Biquad> {
        UnsafeMutableBufferPointer(
            start: UnsafeMutableRawPointer(self).assumingMemoryBound(to: Biquad.self),
            count: DSPChain.sectionCount
        )
    }
}

// MARK: - The realtime chain

/// One-pole gain ramp: move `current` a fraction of the way toward `target`.
@inline(__always)
func rackSmooth(_ current: Float, toward target: Float, coefficient: Float) -> Float {
    current + (target - current) * coefficient
}

/// Run one channel's samples through the chain, in place.
///
/// Realtime. Multiplies and adds only: coefficients arrive pre-computed, and
/// the gain ramp is one multiply-add per sample.
///
/// - Parameters:
///   - stride: 1 for a deinterleaved buffer, or the channel count for an
///     interleaved one, where this channel's samples are every n-th.
@inline(__always)
func rackProcessChannel(
    samples: UnsafeMutablePointer<Float>,
    frameCount: Int,
    stride: Int,
    filters: UnsafeMutableBufferPointer<Biquad>,
    coefficients: UnsafeMutableBufferPointer<BiquadCoefficients>,
    gain: inout Float,
    targetGain: Float,
    smoothing: Float
) {
    // Coefficients are read once per buffer, not per sample: the published
    // block cannot change underneath us mid-buffer, and hoisting the loads
    // keeps the inner loop tight.
    var section = 0
    while section < DSPChain.sectionCount {
        filters[section].coefficients = coefficients[section]
        section += 1
    }

    var frame = 0
    while frame < frameCount {
        let index = frame * stride
        var sample = samples[index]

        var section = 0
        while section < DSPChain.sectionCount {
            sample = filters[section].process(sample)
            section += 1
        }

        // Ramped per sample, which is the point: a per-buffer step would be a
        // discontinuity however small the change.
        gain = rackSmooth(gain, toward: targetGain, coefficient: smoothing)
        samples[index] = sample * gain

        frame += 1
    }
}

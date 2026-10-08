import CoreAudio
import Darwin

/// Headphone stereo crossfeed: bleeds a treble-rolled-off copy of each
/// channel into its opposite, the classic fix for hard-panned recordings
/// sounding harsh on headphones — real speakers give each ear a little of
/// the other channel already, delayed and shadowed by the head; headphones
/// give none of that at all.
///
/// The last stage in the Sound Field Processor's chain, after `rackProcessWidth`:
/// it acts on the final stereo image the user has already shaped, the same
/// reasoning that puts width last among the three.
public enum Crossfeed {
    public static let amountRange: ClosedRange<Double> = 0...1

    /// Corner of the rolloff applied to the crossfeed content. Fixed rather
    /// than a user control — the same "one number to retune, not a knob"
    /// treatment `Compressor.kneeDecibels` gets — modeling roughly where a
    /// real head's shadow starts attenuating the far ear.
    static let shelfFrequency: Double = 700

    /// Depth of that rolloff. A shelf, not a brickwall cut — a real head does
    /// not remove treble entirely, it attenuates it.
    static let shelfCutDecibels: Double = -6

    /// The blend's own ceiling, reached at `amount == 1`. Kept well short of
    /// a full 1:1 blend — crossfeed is meant to be subtle, and a stronger
    /// blend collapses the image rather than merely softening it.
    static let maximumBlendGain: Double = 0.4
}

// MARK: - Compiled coefficients

/// One setting, fully designed for a specific sample rate. Plain old data —
/// what `rackProcessCrossfeed` reads every sample, never what it computes.
struct CrossfeedCoefficients {
    /// The shelf shaping the crossfeed content, reused directly from
    /// `BiquadCoefficients.highShelf` — the same design `EQBank`'s top band
    /// and the tone/boost controls already use, just applied here to the
    /// opposite channel's bleed rather than to the whole signal.
    var filter: BiquadCoefficients = .identity

    /// 0 when disabled — the fixed point at which the crossfeed contributes
    /// nothing, the same "disabled folds to a true no-op" trick every other
    /// effect's coefficients use.
    var blendGain: Float = 0

    /// The direct channel's own gain, mildly cut as `blendGain` rises so
    /// raising crossfeed does not also raise perceived loudness. Exactly 1
    /// when `blendGain` is 0 — the bit-transparent disabled case.
    var directGain: Float = 1

    /// Design a setting for `sampleRate`. Off the audio thread only.
    static func compile(
        amount: Double,
        isEnabled: Bool,
        sampleRate: Double
    ) -> CrossfeedCoefficients {
        var coefficients = CrossfeedCoefficients()
        coefficients.filter = .highShelf(
            frequency: Crossfeed.shelfFrequency,
            gainDecibels: Crossfeed.shelfCutDecibels,
            sampleRate: sampleRate
        )
        let clampedAmount = min(max(amount, Crossfeed.amountRange.lowerBound), Crossfeed.amountRange.upperBound)
        let blendGain = isEnabled ? clampedAmount * Crossfeed.maximumBlendGain : 0
        coefficients.blendGain = Float(blendGain)
        coefficients.directGain = Float(1 - blendGain * 0.5)
        return coefficients
    }
}

/// Headphone crossfeed — the Sound Field Processor's last stage, after
/// width: it acts on the final stereo image the user has already shaped.
/// See `Crossfeed`'s own doc comment for the reasoning behind the design.
///
/// Bypass is handled once by `rackApplyChain`. Skips the walk entirely when
/// `blendGain` is zero, the same bit-transparent-when-disabled guarantee
/// `rackProcessSaturation` keeps for its own `mixWet`.
@inline(__always)
func rackProcessCrossfeed(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let coefficients = block.pointee.crossfeed
    guard coefficients.blendGain > 0 else { return }

    withUnsafeMutablePointer(to: &context.pointee.dsp) { dsp in
        // Coefficients are read once per buffer, the same "not per sample"
        // discipline `rackProcessChannel` keeps for the main chain.
        dsp.pointee.crossfeedLeftFilter.coefficients = coefficients.filter
        dsp.pointee.crossfeedRightFilter.coefficients = coefficients.filter

        let blend = coefficients.blendGain
        let direct = coefficients.directGain

        @inline(__always)
        func mix(left: inout Float, right: inout Float) {
            // Both filtered values are computed before either output sample
            // is written, so neither read ever sees an already-mutated
            // sample from this same frame.
            let filteredFromLeft = dsp.pointee.crossfeedLeftFilter.process(left)
            let filteredFromRight = dsp.pointee.crossfeedRightFilter.process(right)
            left = left * direct + filteredFromRight * blend
            right = right * direct + filteredFromLeft * blend
        }

        rackWalkStereoPairs(buffers: buffers, mix)
    }
}

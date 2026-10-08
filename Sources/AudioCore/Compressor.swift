import CoreAudio
import Darwin
import RackRealtime

/// A feedforward, stereo-linked compressor.
///
/// Stereo-linked because the detector reads `max(|left|, |right|)`, not each
/// channel on its own: a compressor that reacted to each channel
/// independently would pull the two apart under an off-centre signal and
/// audibly shift the stereo image every time it engaged — exactly the
/// problem `rackProcessWidth` exists downstream to shape on purpose, not one
/// this stage should introduce by accident.
///
/// The gain curve runs in the log (dB) domain, the way every real
/// compressor's does — a ratio is a slope in dB, not a linear one — which
/// means a `log10f`/`powf` per sample. That is a real cost next to the
/// multiply-only stages elsewhere in this chain, but it is not an
/// allocation, a lock or anything else `AUDIO.md` actually forbids, and
/// there is no way to compute a compression curve honestly without it.
public enum Compressor {
    public static let thresholdRangeDecibels: ClosedRange<Double> = -48...0
    public static let ratioRange: ClosedRange<Double> = 1...20
    public static let attackRangeMilliseconds: ClosedRange<Double> = 0.1...200
    public static let releaseRangeMilliseconds: ClosedRange<Double> = 10...2000
    public static let makeupRangeDecibels: ClosedRange<Double> = 0...24

    /// Soft-knee width in dB, centred on the threshold. Fixed rather than a
    /// user control — narrow enough that the ratio still reads as what the
    /// knob says once well above threshold, wide enough that the onset of
    /// compression is a curve rather than a corner, which is what keeps a
    /// vocal riding right at the threshold from sounding like it is
    /// chattering on and off.
    public static let kneeDecibels: Float = 6

    /// Below this the detector reads as silence rather than a very large
    /// negative number — the same floor `PeakMeter.floorDecibels` exists
    /// for, on the input side instead of the display side.
    public static let floorDecibels: Float = -96
    static let linearFloor: Float = Float(pow(10.0, Double(floorDecibels) / 20))

    /// Gain reduction below this, in dB, is treated as none at all — the point
    /// at which `rackProcessCompressor` snaps its released envelope to zero and
    /// stops running once the unit is otherwise a no-op. Far below audibility
    /// (a 0.0001 dB gain step), and below the resolution of the reduction
    /// meter, so nothing downstream can tell the snap from the asymptote it
    /// replaces.
    static let reductionSilenceThreshold: Float = 1e-4

    /// One-pole coefficient for an attack or a release time — the same
    /// exponential-ramp shape `DSPRenderState.smoothingCoefficient` and
    /// `Reverb.crossfadeCoefficient` use, just parameterised by whichever of
    /// the two times is asked for. Attack and release differ only in *which*
    /// time reaches this function, never in the formula itself.
    public static func timeCoefficient(milliseconds: Double, sampleRate: Double) -> Float {
        guard sampleRate > 0, milliseconds > 0 else { return 1 }
        return Float(1 - exp(-1 / (milliseconds / 1000 * sampleRate)))
    }
}

// MARK: - Compiled coefficients

/// One setting, fully designed for a specific sample rate. Plain old data —
/// what `rackProcessCompressor` reads every sample, never what it computes.
struct CompressorCoefficients {
    var thresholdDecibels: Float = 0

    /// 1 when disabled — the fixed point of the gain-reduction formula
    /// below at which every detector level produces zero reduction, the
    /// same "fold the enable switch into the coefficients so the realtime
    /// path needs no separate bypass branch" trick `ReverbCoefficients` and
    /// `DelayCoefficients` already use for their own `isEnabled`.
    var ratio: Float = 1

    var attackCoefficient: Float = 1
    var releaseCoefficient: Float = 1

    /// Also zeroed when disabled, for the same reason: a disabled
    /// compressor must be a true no-op, not a unity-gain-reduction unit
    /// that still adds makeup gain.
    var makeupDecibels: Float = 0

    /// Design a setting for `sampleRate`. Off the audio thread only.
    static func compile(
        thresholdDecibels: Double,
        ratio: Double,
        attackMilliseconds: Double,
        releaseMilliseconds: Double,
        makeupDecibels: Double,
        isEnabled: Bool,
        sampleRate: Double
    ) -> CompressorCoefficients {
        var coefficients = CompressorCoefficients()
        coefficients.thresholdDecibels = Float(
            min(max(thresholdDecibels, Compressor.thresholdRangeDecibels.lowerBound),
                Compressor.thresholdRangeDecibels.upperBound)
        )
        coefficients.ratio = isEnabled
            ? Float(min(max(ratio, Compressor.ratioRange.lowerBound), Compressor.ratioRange.upperBound))
            : 1
        coefficients.attackCoefficient = Compressor.timeCoefficient(
            milliseconds: min(max(attackMilliseconds, Compressor.attackRangeMilliseconds.lowerBound),
                               Compressor.attackRangeMilliseconds.upperBound),
            sampleRate: sampleRate
        )
        coefficients.releaseCoefficient = Compressor.timeCoefficient(
            milliseconds: min(max(releaseMilliseconds, Compressor.releaseRangeMilliseconds.lowerBound),
                               Compressor.releaseRangeMilliseconds.upperBound),
            sampleRate: sampleRate
        )
        coefficients.makeupDecibels = isEnabled
            ? Float(min(max(makeupDecibels, 0), Compressor.makeupRangeDecibels.upperBound))
            : 0
        return coefficients
    }
}

// MARK: - Realtime

/// Realtime. The static transfer curve's implied gain reduction, in dB, for
/// one instantaneous detector reading — the *target* `rackProcessCompressor`
/// chases via the attack/release coefficients, not what it applies directly.
/// A compressor with no envelope smoothing would react to a single loud
/// sample rather than a genuine rise in level, and would sound like
/// distortion rather than compression.
///
/// The standard soft-knee formula (Giannoulis, Massberg & Reiss, "Digital
/// Dynamic Range Compressor Design", 2012): a parabola of width
/// `Compressor.kneeDecibels` blends between "no reduction" below the knee
/// and the straight `1 − 1/ratio` slope above it, so the onset of
/// compression is a curve rather than a corner. Always ≥ 0, since `ratio`
/// never goes below 1.
@inline(__always)
func rackCompressorTargetReduction(
    detectorDecibels: Float,
    coefficients: CompressorCoefficients
) -> Float {
    let knee = Compressor.kneeDecibels
    let overshoot = detectorDecibels - coefficients.thresholdDecibels
    let slope = 1 - 1 / coefficients.ratio

    if 2 * overshoot < -knee {
        return 0
    } else if 2 * abs(overshoot) <= knee {
        let x = overshoot + knee / 2
        return slope * (x * x) / (2 * knee)
    } else {
        return overshoot * slope
    }
}

/// Compresses the fully-filtered, fully-gained signal `rackProcess` just
/// produced — after tone and volume have shaped the signal, before the
/// Sound Field Processor adds anything to it. Compressing a reverb or echo
/// tail rather than the dry signal driving them pumps in a way no real
/// compressor placed ahead of a send effect ever would.
///
/// Bypass is handled once by `rackApplyChain`, for the same reason it always
/// was: a fault in parameter compilation must never mean silence, and the
/// panic path must never depend on this pass having run.
@inline(__always)
func rackProcessCompressor(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let coefficients = block.pointee.compressor

    // A compressor that can produce no reduction and adds no makeup does
    // nothing — whether because the user switched it off (compiled to ratio 1,
    // makeup 0) or dialled the ratio to unity by hand. Once its envelope has
    // released to silence there is nothing left to smooth, so the pass skips
    // the per-sample `log10f`/`powf` rather than spending them to multiply by
    // one — the same "disabled is genuinely no work" guarantee saturation and
    // crossfeed keep. The remnant is snapped to exact zero on the way in (a
    // sub-0.0001 dB step, inaudible) so the skipped pass is a true
    // bit-transparent no-op, and the reduction meter is left reading zero.
    if coefficients.ratio == 1, coefficients.makeupDecibels == 0,
       context.pointee.compressorEnvelopeDb <= Compressor.reductionSilenceThreshold {
        if context.pointee.compressorEnvelopeDb != 0 {
            context.pointee.compressorEnvelopeDb = 0
            rack_u32_store(&context.pointee.compressorReductionBits, Float(0).bitPattern)
        }
        return
    }

    @inline(__always)
    func mix(left: inout Float, right: inout Float) {
        // Stereo-linked: one detector for both channels, so gain reduction
        // never pulls the image apart — see the type's own doc comment.
        let detector = max(abs(left), abs(right))
        let detectorDecibels = detector > Compressor.linearFloor
            ? 20 * log10f(detector)
            : Compressor.floorDecibels

        let target = rackCompressorTargetReduction(
            detectorDecibels: detectorDecibels, coefficients: coefficients
        )
        // Louder calls for *more* reduction, chased at the attack rate;
        // anything else is the reduction relaxing, chased at the release
        // rate — attack and release are properties of the gain-reduction
        // signal, not of the raw level.
        let coefficient = target > context.pointee.compressorEnvelopeDb
            ? coefficients.attackCoefficient
            : coefficients.releaseCoefficient
        context.pointee.compressorEnvelopeDb = rackSmooth(
            context.pointee.compressorEnvelopeDb, toward: target, coefficient: coefficient
        )

        let gain = powf(
            10, (coefficients.makeupDecibels - context.pointee.compressorEnvelopeDb) / 20
        )
        left *= gain
        right *= gain
    }

    rackWalkStereoPairs(buffers: buffers, mix)
    rack_u32_store(&context.pointee.compressorReductionBits, context.pointee.compressorEnvelopeDb.bitPattern)
}

import CoreAudio
import Darwin

/// Tape/tube-style harmonic saturation: a stateless `tanh` waveshaper,
/// dry/wet blended into the fully-filtered signal `rackProcess` just
/// produced.
///
/// Placed ahead of the compressor, not after it: warmth is a character of
/// the amplifier stage itself, and compressing already-saturated harmonics —
/// the standard tape-into-bus-compressor order — is what glues them together,
/// rather than compressing a clean signal and saturating the result.
public enum Saturation {
    public static let driveRangeDecibels: ClosedRange<Double> = 0...24
    public static let mixRange: ClosedRange<Double> = 0...1
}

// MARK: - Compiled coefficients

/// One setting, fully designed. Plain old data — what `rackProcessSaturation`
/// reads every sample, never what it computes.
struct SaturationCoefficients {
    var driveGain: Float = 1

    /// Compensates the level `tanh` compression takes away as drive rises,
    /// so cranking the knob adds harmonics without also just getting louder.
    var makeupGain: Float = 1

    /// 0 when disabled — the fixed point of the blend at which the stage is
    /// a true no-op, the same trick `CompressorCoefficients.ratio = 1` uses
    /// for its own disabled case.
    var mixWet: Float = 0

    /// Design a setting. Off the audio thread only — `tanh` has no business
    /// in an IOProc, the same reasoning `AUDIO.md` gives for `pow`/`sin`/`cos`
    /// in every other section design.
    static func compile(
        driveDecibels: Double,
        mix: Double,
        isEnabled: Bool
    ) -> SaturationCoefficients {
        var coefficients = SaturationCoefficients()
        let drive = min(
            max(driveDecibels, Saturation.driveRangeDecibels.lowerBound),
            Saturation.driveRangeDecibels.upperBound
        )
        let driveGain = pow(10, drive / 20)
        coefficients.driveGain = Float(driveGain)
        coefficients.makeupGain = Float(1 / tanh(driveGain))
        coefficients.mixWet = isEnabled
            ? Float(min(max(mix, Saturation.mixRange.lowerBound), Saturation.mixRange.upperBound))
            : 0
        return coefficients
    }
}

// MARK: - Realtime

/// One sample through the waveshaper, dry/wet blended.
///
/// Realtime. `tanhf` is a real transcendental call per sample — the same
/// class of cost `AUDIO.md` already accepts for the compressor's
/// `log10f`/`powf`, not an allocation or a lock, and there is no way to
/// saturate honestly without a nonlinearity.
@inline(__always)
func rackSaturate(_ input: Float, coefficients: SaturationCoefficients) -> Float {
    let driven = tanhf(input * coefficients.driveGain) * coefficients.makeupGain
    return input + (driven - input) * coefficients.mixWet
}

/// Runs tape/tube saturation over the fully-filtered, fully-gained signal
/// `rackProcess` just produced, ahead of the compressor — see `Saturation`'s
/// own doc comment for why that ordering is chosen.
///
/// Same double bypass as `rackProcess`. Skips the walk entirely when
/// `mixWet` is zero — disabled is bit-identical passthrough, not merely
/// close, the same "flat is bit-transparent" guarantee `DSPChain` keeps for
/// the EQ.
@inline(__always)
func rackProcessSaturation(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let coefficients = block.pointee.saturation
    guard coefficients.mixWet > 0 else { return }

    @inline(__always)
    func mix(left: inout Float, right: inout Float) {
        left = rackSaturate(left, coefficients: coefficients)
        right = rackSaturate(right, coefficients: coefficients)
    }

    rackWalkStereoPairs(buffers: buffers, mix)
}

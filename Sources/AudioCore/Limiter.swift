import CoreAudio
import Darwin
import RackRealtime

/// The chain's last line of defence: a stereo-linked brickwall limiter that
/// holds the output at or below a ceiling.
///
/// It exists because nothing else in the chain does this job. Headroom
/// compensation is a *predictive* cut, computed off the audio thread by
/// sweeping the filter response, and it is applied at the output stage —
/// before saturation makeup, before compressor makeup, and before the reverb
/// and echo mix their wet signal in. Every one of those can raise the level
/// after the only thing that was watching it has already decided how much to
/// take off. Stack a boosted band, 12 dB of drive, makeup gain and a wet
/// reverb and the chain can hand the DAC something well past full scale.
///
/// **Sample-peak, not true-peak.** This bounds the samples it can see. A
/// signal that passes under the ceiling can still reconstruct to an
/// inter-sample peak above it in the DAC's own filter — catching that means
/// oversampling the detector, which is a separate piece of work. What is here
/// is what stops the chain's own gain staging from clipping, which is the
/// failure that was actually reachable from the front panel.
///
/// Attack is instantaneous by construction rather than a time constant: the
/// gain needed to bring *this* sample under the ceiling is applied to *this*
/// sample. That is what makes the ceiling a guarantee rather than a target,
/// and it is why there is no look-ahead buffer and no added latency. The cost
/// is that a hard transient is shaped rather than delayed into — audible as a
/// brief dulling on material that hits the ceiling constantly, which is the
/// standard trade a limiter without look-ahead makes.
public enum Limiter {
    /// How far below full scale the ceiling can be set. 0 dBFS is the top; the
    /// range goes down far enough to use this as a deliberate output trim.
    public static let ceilingRangeDecibels: ClosedRange<Double> = -12...0

    /// A hair under full scale by default. Not 0 dBFS: a converter's
    /// reconstruction filter can overshoot a signal that sits exactly at the
    /// top, and the fraction of a decibel this gives up is inaudible next to
    /// the clipping it avoids.
    public static let defaultCeilingDecibels: Double = -0.3

    public static let releaseRangeMilliseconds: ClosedRange<Double> = 10...500

    /// Long enough not to pump on sustained material, short enough that one
    /// loud transient does not duck the next second of music.
    public static let defaultReleaseMilliseconds: Double = 100

    /// One-pole coefficient for the release, the same exponential-ramp shape
    /// `Compressor.timeCoefficient` and `DSPRenderState.smoothingCoefficient`
    /// use. There is no attack equivalent: attack is immediate.
    public static func releaseCoefficient(
        milliseconds: Double, sampleRate: Double
    ) -> Float {
        guard sampleRate > 0, milliseconds > 0 else { return 1 }
        return Float(1 - exp(-1 / (milliseconds / 1000 * sampleRate)))
    }
}

// MARK: - Compiled coefficients

/// One setting, designed for a specific sample rate. Plain old data — what
/// `rackProcessLimiter` reads, never what it computes.
struct LimiterCoefficients {
    /// The ceiling as a linear amplitude, which is the form the detector
    /// compares against — converting a decibel value per sample would be a
    /// `powf` in the inner loop for a number that never changes within a
    /// buffer.
    var ceiling: Float = 1

    var releaseCoefficient: Float = 1

    /// Folded from `isLimiterEnabled`, the same "the realtime path reads one
    /// flag rather than re-deriving the user's switch" convention
    /// `ReverbCoefficients.wetGain` and `CompressorCoefficients.ratio` use.
    var isActive: Bool = false

    /// Design a setting. Off the audio thread only — `pow` and `exp` both
    /// live here.
    static func compile(
        ceilingDecibels: Double,
        releaseMilliseconds: Double,
        isEnabled: Bool,
        sampleRate: Double
    ) -> LimiterCoefficients {
        var coefficients = LimiterCoefficients()
        let ceiling = min(
            max(ceilingDecibels, Limiter.ceilingRangeDecibels.lowerBound),
            Limiter.ceilingRangeDecibels.upperBound
        )
        coefficients.ceiling = Float(pow(10, ceiling / 20))
        coefficients.releaseCoefficient = Limiter.releaseCoefficient(
            milliseconds: min(
                max(releaseMilliseconds, Limiter.releaseRangeMilliseconds.lowerBound),
                Limiter.releaseRangeMilliseconds.upperBound
            ),
            sampleRate: sampleRate
        )
        coefficients.isActive = isEnabled
        return coefficients
    }
}

// MARK: - Realtime

/// Realtime. The gain this sample needs to sit at or under the ceiling — 1
/// when it already does, so a signal that never reaches the ceiling is
/// multiplied by exactly one and passes through bit-identically.
///
/// Split out from the buffer walk so the arithmetic can be tested directly:
/// what a limiter has to guarantee is a property of this function, not of how
/// the buffer is traversed.
@inline(__always)
func rackLimiterRequiredGain(peak: Float, ceiling: Float) -> Float {
    guard peak > ceiling, peak > 0 else { return 1 }
    return ceiling / peak
}

/// Hold the output at or below the ceiling — the chain's final stage.
///
/// Stereo-linked, like the compressor's detector and for the same reason: a
/// limiter that pulled one channel down on its own would swing the stereo
/// image every time it engaged. Attack is instantaneous, so the ceiling is a
/// guarantee rather than a target — see `Limiter` for why that trade is the
/// right one here and what it costs.
@inline(__always)
func rackProcessLimiter(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let coefficients = block.pointee.limiter

    // Switched off, and already released back to unity: nothing to do and
    // nothing to smooth. Defeating the limiter mid-peak still releases
    // smoothly rather than stepping, which is why the gain is checked too.
    if !coefficients.isActive, context.pointee.limiterGain >= 1 {
        return
    }

    let release = coefficients.releaseCoefficient
    // A defeated limiter releases toward unity rather than snapping there.
    let ceiling = coefficients.isActive ? coefficients.ceiling : .greatestFiniteMagnitude

    @inline(__always)
    func mix(left: inout Float, right: inout Float) {
        let peak = max(abs(left), abs(right))
        let required = rackLimiterRequiredGain(peak: peak, ceiling: ceiling)

        // Instant attack, smoothed release. Taking the needed gain immediately
        // is what bounds the output: by the time this sample is multiplied,
        // the gain already accounts for it.
        if required < context.pointee.limiterGain {
            context.pointee.limiterGain = required
        } else {
            context.pointee.limiterGain = rackSmooth(
                context.pointee.limiterGain, toward: required, coefficient: release
            )
        }

        left *= context.pointee.limiterGain
        right *= context.pointee.limiterGain
    }

    rackWalkStereoPairs(buffers: buffers, mix)

    // Published as a positive number of decibels of reduction, matching the
    // compressor's own meter convention. `limiterGain` is ≤ 1, so the log is
    // ≤ 0 and the sign flips.
    let reduction = context.pointee.limiterGain < 1
        ? -20 * log10f(max(context.pointee.limiterGain, 1e-6))
        : 0
    rack_u32_store(&context.pointee.limiterReductionBits, reduction.bitPattern)
}

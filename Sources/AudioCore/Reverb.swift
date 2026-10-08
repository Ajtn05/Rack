import Darwin

/// The Sound Field Processor: a feedback delay network reverb.
///
/// Four delay lines per channel, mixed through a lossless Hadamard matrix and
/// fed back through a per-line decay gain and a shared damping filter — the
/// standard Schroeder/Jot shape. A lossless mixing matrix is what lets the
/// whole of a preset's RT60 live in one place (`feedbackGain`): the matrix
/// itself neither adds nor removes energy, so nothing downstream of it can
/// silently make a preset decay faster or slower than the number it was
/// designed for.
///
/// Everything in this file that touches `pow`, `sin`, `cos` or division is
/// off the audio thread only, exactly like `BiquadCoefficients`' design
/// functions. `ReverbVoiceState.process` is the one piece that runs on the
/// IOProc, and it is multiplies, adds and array subscripts — nothing else.
public enum Reverb {
    /// Highest sample rate any pre-allocated buffer has to cover. Real output
    /// devices run at or under this; one that somehow runs higher has its
    /// line lengths clamped to what actually fits (see `ReverbCoefficients`)
    /// rather than allocating late or overrunning the buffer.
    public static let maximumSampleRate: Double = 192_000

    /// The four comb lengths a Schroeder-style FDN spreads its taps across,
    /// in milliseconds at `roomSize == 1`. Close to mutually prime ratios so
    /// the four lines' own resonances do not reinforce into an audible
    /// ringing tone — the classic failure mode of a comb-filter reverb built
    /// from round numbers.
    public static let lineLengthsMilliseconds: [Double] = [29.7, 37.1, 41.3, 43.7]

    public static let lineCount = 4

    /// The largest `ReverbPreset.roomSize` — Stadium's. Combined with
    /// `lineLengthsMilliseconds` this is what each delay line's buffer is
    /// sized to, once, at session start.
    public static let maximumRoomSize: Double = 2.0

    /// The longest any preset's pre-delay runs — Stadium's again.
    public static let maximumPreDelayMilliseconds: Double = 60

    /// A small per-line offset added to the right channel only, so the two
    /// channels' tails decorrelate instead of collapsing toward mono the
    /// moment they are summed — a standard, cheap stereo-widening trick for
    /// a small FDN. Kept far smaller than the lines themselves so it never
    /// meaningfully changes a preset's own character.
    public static let rightChannelOffsetsMilliseconds: [Double] = [0.15, 0.23, 0.11, 0.19]

    /// How long a preset switch crossfades. Long enough that the ear does not
    /// catch the splice, short enough that picking a new space feels
    /// immediate rather than sluggish.
    public static let crossfadeSeconds: Double = 0.05

    /// Below this weight a fading voice's contribution is inaudible, and it
    /// stops being processed until it is next chosen as a target — the
    /// difference between "always running two networks" and "briefly running
    /// two during a switch".
    static let crossfadeSilenceThreshold: Float = 0.001

    // MARK: - Sizing

    /// Samples one line's buffer needs at the worst case of every preset and
    /// both channels — the capacity allocated once, at session start.
    public static func maximumLineSamples(forLine index: Int) -> Int {
        guard lineLengthsMilliseconds.indices.contains(index) else { return 0 }
        let milliseconds = lineLengthsMilliseconds[index] * maximumRoomSize
            + rightChannelOffsetsMilliseconds[index]
        return Int((milliseconds / 1000 * maximumSampleRate).rounded(.up)) + 1
    }

    public static func maximumPreDelaySamples() -> Int {
        Int((maximumPreDelayMilliseconds / 1000 * maximumSampleRate).rounded(.up)) + 1
    }

    /// One line's active length for a given room size, channel and rate,
    /// clamped to what `maximumLineSamples` actually allocated — the guard
    /// against a device running above `maximumSampleRate`.
    public static func lineSamples(
        forLine index: Int,
        roomSize: Double,
        isRightChannel: Bool,
        sampleRate: Double
    ) -> Int {
        guard lineLengthsMilliseconds.indices.contains(index) else { return 1 }
        var milliseconds = lineLengthsMilliseconds[index] * roomSize
        if isRightChannel { milliseconds += rightChannelOffsetsMilliseconds[index] }
        let samples = Int((milliseconds / 1000 * sampleRate).rounded())
        return min(max(samples, 1), maximumLineSamples(forLine: index))
    }

    public static func preDelaySamples(
        milliseconds: Double,
        sampleRate: Double
    ) -> Int {
        let samples = Int((milliseconds / 1000 * sampleRate).rounded())
        return min(max(samples, 1), maximumPreDelaySamples())
    }

    // MARK: - Design

    /// The feedback gain that brings one line's recirculating level down by
    /// 60 dB after `decaySeconds` of repeated passes.
    ///
    /// After `n = decaySeconds / delaySeconds` passes the level must reach
    /// `10^(-60/20)`, so `gain^n = 10^-3` and `gain = 10^(-3 * delaySeconds /
    /// decaySeconds)` — the standard Schroeder/Jot relation, and the reason a
    /// lossless mixing matrix matters: with one, this gain alone determines
    /// the preset's RT60, so what `ReverbPresetTests` measures is exactly
    /// what this computes.
    public static func feedbackGain(
        lineSamples: Int,
        decaySeconds: Double,
        sampleRate: Double
    ) -> Float {
        guard decaySeconds > 0, sampleRate > 0, lineSamples > 0 else { return 0 }
        let delaySeconds = Double(lineSamples) / sampleRate
        return Float(pow(10, -3 * delaySeconds / decaySeconds))
    }

    /// A normalised 4×4 Hadamard matrix: every row and column orthogonal, and
    /// every entry ±½ so the matrix preserves total energy exactly. That
    /// losslessness is the whole point — it is what lets `feedbackGain` alone
    /// carry a preset's decay time, with nothing here adding or removing any.
    @inline(__always)
    public static func hadamardMix(
        _ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float
    ) -> (Float, Float, Float, Float) {
        let half: Float = 0.5
        return (
            half * (x0 + x1 + x2 + x3),
            half * (x0 - x1 + x2 - x3),
            half * (x0 + x1 - x2 - x3),
            half * (x0 - x1 - x2 + x3)
        )
    }

    /// One-pole coefficient for the ~50 ms preset crossfade — the same
    /// exponential-ramp shape `DSPRenderState.smoothingCoefficient` uses for
    /// gain, just with a much longer time constant so a preset switch fades
    /// rather than steps.
    public static func crossfadeCoefficient(forSampleRate sampleRate: Double) -> Float {
        guard sampleRate > 0 else { return 1 }
        return Float(1 - exp(-1 / (crossfadeSeconds * sampleRate)))
    }
}

// MARK: - Compiled coefficients

/// One preset, fully designed for a specific sample rate. Plain old data —
/// what `DSPBlock` carries and what the audio thread reads, never what it
/// computes.
struct ReverbCoefficients: CrossfadeCoefficients {
    var lineSamplesLeft: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var lineSamplesRight: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)

    /// One gain per line. Computed from the left channel's line length; the
    /// right channel's decorrelation offset is a fraction of a millisecond
    /// and the difference in decay it would imply is inaudible, so both
    /// channels share these.
    var feedbackGains: (Float, Float, Float, Float) = (0, 0, 0, 0)

    var dampingCoefficient: Float = 0
    var preDelaySamples: Int32 = 1

    /// `ReverbPreset.index`, or −1 for no preset compiled yet. How a voice
    /// tells "this is what I am already configured for" from "a switch just
    /// arrived" without comparing every derived field above.
    var presetIndex: Int32 = -1

    /// Equal-power wet/dry, already folding in `isReverbEnabled` — disabled
    /// is wetGain 0, dryGain 1, exactly as if the wet amount were zero.
    var wetGain: Float = 0
    var dryGain: Float = 1

    /// Design a preset for `sampleRate`, clamped to what the pre-allocated
    /// buffers can actually hold. Off the audio thread only — `pow` and the
    /// per-line design both live here.
    static func compile(
        preset: ReverbPreset,
        wetAmount: Double,
        isEnabled: Bool,
        sampleRate: Double
    ) -> ReverbCoefficients {
        let rate = min(sampleRate > 0 ? sampleRate : Reverb.maximumSampleRate, Reverb.maximumSampleRate)
        let design = preset.design

        var left: [Int32] = []
        var right: [Int32] = []
        var gains: [Float] = []
        for line in 0..<Reverb.lineCount {
            let leftSamples = Reverb.lineSamples(
                forLine: line, roomSize: design.roomSize,
                isRightChannel: false, sampleRate: rate
            )
            let rightSamples = Reverb.lineSamples(
                forLine: line, roomSize: design.roomSize,
                isRightChannel: true, sampleRate: rate
            )
            left.append(Int32(leftSamples))
            right.append(Int32(rightSamples))
            gains.append(
                Reverb.feedbackGain(
                    lineSamples: leftSamples, decaySeconds: design.decaySeconds, sampleRate: rate
                )
            )
        }

        let wet = min(max(wetAmount, 0), 1)
        // Equal-power crossfade, computed here rather than on the audio
        // thread: `sin`/`cos` have no business in an IOProc.
        let radians = wet * .pi / 2
        let wetGain: Float = isEnabled ? Float(sin(radians)) : 0
        let dryGain: Float = isEnabled ? Float(cos(radians)) : 1

        var coefficients = ReverbCoefficients()
        coefficients.lineSamplesLeft = (left[0], left[1], left[2], left[3])
        coefficients.lineSamplesRight = (right[0], right[1], right[2], right[3])
        coefficients.feedbackGains = (gains[0], gains[1], gains[2], gains[3])
        coefficients.dampingCoefficient = Float(min(max(design.damping, 0), 1))
        coefficients.preDelaySamples = Int32(
            Reverb.preDelaySamples(milliseconds: design.preDelayMilliseconds, sampleRate: rate)
        )
        coefficients.presetIndex = preset.index
        coefficients.wetGain = wetGain
        coefficients.dryGain = dryGain
        return coefficients
    }
}

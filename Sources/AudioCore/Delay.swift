import CoreAudio
import Darwin

/// A stereo echo, distinct from the Sound Field Processor's reverb.
///
/// One delay line per channel, each with its own tap time and a shared
/// feedback and damping character — a fundamentally simpler topology than
/// `Reverb`'s four-line Hadamard-mixed network, and deliberately so: a
/// Hadamard mix exists specifically to *diffuse* energy across lines so no
/// single repeat is audible on its own, which is exactly the opposite of
/// what an echo needs. A clean, countable repeat wants one line, read and
/// fed back on itself, and nothing decorrelating it.
///
/// Left and right run independent delay times, which is what turns a plain
/// echo into a "Ping-Pong" preset — no cross-channel feedback coupling
/// required, just two taps that land at different moments.
public enum Delay {
    /// Shares `Reverb`'s own ceiling — no reason for the two effects to
    /// disagree about what a device might ask for.
    public static let maximumSampleRate: Double = Reverb.maximumSampleRate

    /// The longest any preset's delay runs (Dub's), plus headroom — the
    /// figure each line's buffer is sized to, once, at session start.
    public static let maximumDelayMilliseconds: Double = 600

    /// Same crossfade duration as a reverb preset switch, for the same
    /// reason: long enough the ear does not catch the splice, short enough
    /// that picking a new echo feels immediate.
    public static let crossfadeSeconds: Double = 0.05

    static let crossfadeSilenceThreshold: Float = 0.001

    // MARK: - Sizing

    public static func maximumLineSamples() -> Int {
        Int((maximumDelayMilliseconds / 1000 * maximumSampleRate).rounded(.up)) + 1
    }

    /// One line's active length for a delay time and rate, clamped to what
    /// `maximumLineSamples` actually allocated.
    public static func lineSamples(milliseconds: Double, sampleRate: Double) -> Int {
        let samples = Int((milliseconds / 1000 * sampleRate).rounded())
        return min(max(samples, 1), maximumLineSamples())
    }

    /// One-pole coefficient for the preset crossfade — the same shape
    /// `Reverb.crossfadeCoefficient` uses.
    public static func crossfadeCoefficient(forSampleRate sampleRate: Double) -> Float {
        guard sampleRate > 0 else { return 1 }
        return Float(1 - exp(-1 / (crossfadeSeconds * sampleRate)))
    }
}

// MARK: - Presets

/// The Sound Field Processor's named echoes.
///
/// Four fixed characters rather than raw time/feedback knobs, the same
/// "a named space reads as a place rather than a setting" choice
/// `ReverbPreset` makes for its own six.
public enum DelayPreset: String, CaseIterable, Equatable, Sendable, Codable {
    case slapback
    case echo
    case pingPong
    case dub

    public struct Design: Equatable, Sendable {
        /// The left line's tap time, in milliseconds.
        public let leftDelayMilliseconds: Double

        /// The right line's — equal to the left for every preset except
        /// Ping-Pong, whose whole character is the two channels landing at
        /// different moments.
        public let rightDelayMilliseconds: Double

        /// Recirculation gain, 0…1. How much of a repeat feeds the next one;
        /// 0 is a single, non-repeating slap.
        public let feedback: Double

        /// How much duller each successive repeat is, 0…1 — tape and analog
        /// echoes lose top end every time round the loop; 0 leaves every
        /// repeat as bright as the last.
        public let damping: Double
    }

    public var design: Design {
        switch self {
        case .slapback:
            // A single close-set repeat and nothing after it — the classic
            // rockabilly vocal slap, not a rhythmic effect.
            Design(leftDelayMilliseconds: 90, rightDelayMilliseconds: 90, feedback: 0.0, damping: 0.2)
        case .echo:
            // A plain, moderate repeat with a handful of audible reflections.
            Design(leftDelayMilliseconds: 350, rightDelayMilliseconds: 350, feedback: 0.35, damping: 0.3)
        case .pingPong:
            // Different times per channel bounce the repeats between
            // speakers rather than stacking them dead centre.
            Design(leftDelayMilliseconds: 280, rightDelayMilliseconds: 420, feedback: 0.45, damping: 0.35)
        case .dub:
            // Long, dark, and self-sustaining — repeats that are still
            // audible well after the source has stopped.
            Design(leftDelayMilliseconds: 500, rightDelayMilliseconds: 500, feedback: 0.6, damping: 0.55)
        }
    }

    public var displayName: String {
        switch self {
        case .slapback: "Slapback"
        case .echo: "Echo"
        case .pingPong: "Ping-Pong"
        case .dub: "Dub"
        }
    }

    /// The time this preset's own readout shows — the left line's, since
    /// that is what both channels share except on Ping-Pong, where it is
    /// the shorter and more audible of the two.
    public var timeMilliseconds: Double { design.leftDelayMilliseconds }

    /// A stable small integer per case, the same "changed vs. republished
    /// unchanged" comparison `ReverbPreset.index` exists for.
    var index: Int32 {
        switch self {
        case .slapback: 0
        case .echo: 1
        case .pingPong: 2
        case .dub: 3
        }
    }
}

// MARK: - Compiled coefficients

/// One preset, fully designed for a specific sample rate. Plain old data —
/// what `DSPBlock` carries and what the audio thread reads, never what it
/// computes.
struct DelayCoefficients: CrossfadeCoefficients {
    var leftLineSamples: Int32 = 1
    var rightLineSamples: Int32 = 1
    var feedbackGain: Float = 0
    var dampingCoefficient: Float = 0

    /// `DelayPreset.index`, or −1 for no preset compiled yet.
    var presetIndex: Int32 = -1

    /// Equal-power wet/dry, already folding in `isEnabled` — disabled is
    /// wetGain 0, dryGain 1, the same convention `ReverbCoefficients` uses.
    var wetGain: Float = 0
    var dryGain: Float = 1

    /// Design a preset for `sampleRate`. Off the audio thread only.
    static func compile(
        preset: DelayPreset,
        wetAmount: Double,
        isEnabled: Bool,
        sampleRate: Double
    ) -> DelayCoefficients {
        let rate = min(sampleRate > 0 ? sampleRate : Delay.maximumSampleRate, Delay.maximumSampleRate)
        let design = preset.design

        let wet = min(max(wetAmount, 0), 1)
        let radians = wet * .pi / 2
        let wetGain: Float = isEnabled ? Float(sin(radians)) : 0
        let dryGain: Float = isEnabled ? Float(cos(radians)) : 1

        var coefficients = DelayCoefficients()
        coefficients.leftLineSamples = Int32(
            Delay.lineSamples(milliseconds: design.leftDelayMilliseconds, sampleRate: rate)
        )
        coefficients.rightLineSamples = Int32(
            Delay.lineSamples(milliseconds: design.rightDelayMilliseconds, sampleRate: rate)
        )
        coefficients.feedbackGain = Float(min(max(design.feedback, 0), 1))
        coefficients.dampingCoefficient = Float(min(max(design.damping, 0), 1))
        coefficients.presetIndex = preset.index
        coefficients.wetGain = wetGain
        coefficients.dryGain = dryGain
        return coefficients
    }
}

// MARK: - Realtime state

/// One delay line's buffer and the feedback path's state between samples.
/// Allocated once, at its worst-case length — a preset switch only ever
/// changes how far into the same buffer the write pointer wraps, exactly
/// the reason `ReverbLineState` never reallocates either.
struct DelayLineState {
    var buffer: UnsafeMutablePointer<Float>
    let capacity: Int32
    var length: Int32 = 1
    var writeIndex: Int32 = 0
    var dampState: Float = 0
    var feedbackGain: Float = 0
}

/// Realtime. Reads the sample about to be overwritten — `length` samples
/// old, since the pointer wraps every `length` writes — and damps it. The
/// feedback gain is applied at `writeDelayLine`, not here: what this
/// returns is the tap presented to the wet/dry mix, and that should read at
/// the damped level a listener actually hears, not pre-scaled by how much
/// of it recirculates.
@inline(__always)
private func readDelayLine(_ line: inout DelayLineState, dampingCoefficient: Float) -> Float {
    let delayed = line.buffer[Int(line.writeIndex)]
    line.dampState = (1 - dampingCoefficient) * delayed + dampingCoefficient * line.dampState
    return line.dampState
}

@inline(__always)
private func writeDelayLine(_ line: inout DelayLineState, value: Float) {
    line.buffer[Int(line.writeIndex)] = value
    line.writeIndex += 1
    if line.writeIndex >= line.length { line.writeIndex = 0 }
}

/// One complete echo, left and right lines together. A voice is either the
/// crossfade's current target or the one fading out of it — see
/// `DelayEngine` — the same shape `ReverbVoiceState` uses for the same
/// reason: switching presets never touches a buffer still contributing to
/// the output.
struct DelayVoiceState: CrossfadeVoice {
    typealias Coefficients = DelayCoefficients
    static var crossfadeSilenceThreshold: Float { Delay.crossfadeSilenceThreshold }

    var left: DelayLineState
    var right: DelayLineState

    /// Stored per voice, not passed in from `DelayEngine.process` — a voice
    /// fading out of a switch must keep damping at the rate *it* was
    /// designed for, not the incoming preset's, the same reason
    /// `ReverbVoiceState.dampingCoefficient` lives on the voice rather than
    /// the engine.
    var dampingCoefficient: Float = 0

    /// `DelayPreset.index` this voice is currently designed for, or −1 for
    /// "never configured" — silent, and safe to repurpose immediately.
    var currentPresetIndex: Int32 = -1

    static func allocate() -> DelayVoiceState {
        func line() -> DelayLineState {
            let capacity = Delay.maximumLineSamples()
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            return DelayLineState(buffer: buffer, capacity: Int32(capacity), length: Int32(capacity))
        }
        return DelayVoiceState(left: line(), right: line())
    }

    mutating func free() {
        left.buffer.deallocate()
        right.buffer.deallocate()
    }

    /// Adopt a preset and silence the lines for it. Meant to run once, at
    /// the instant `DelayEngine` detects a switch, not on every buffer.
    mutating func reconfigure(to coefficients: DelayCoefficients) {
        func apply(_ line: inout DelayLineState, length: Int32) {
            line.length = min(max(length, 1), line.capacity)
            line.feedbackGain = coefficients.feedbackGain
            line.writeIndex = 0
            line.dampState = 0
            line.buffer.update(repeating: 0, count: Int(line.capacity))
        }
        apply(&left, length: coefficients.leftLineSamples)
        apply(&right, length: coefficients.rightLineSamples)
        dampingCoefficient = coefficients.dampingCoefficient
        currentPresetIndex = coefficients.presetIndex
    }

    /// Empty both lines without touching this voice's preset configuration —
    /// its lengths, feedback gain and damping stay as they were. Called when
    /// the echo wakes from the idle state `rackProcessDelay` drops it into once
    /// switched off, so its repeats build up from silence rather than replaying
    /// stale buffer contents. The same reasoning as `ReverbVoiceState.silence`.
    mutating func silence() {
        func clear(_ line: inout DelayLineState) {
            line.writeIndex = 0
            line.dampState = 0
            line.buffer.update(repeating: 0, count: Int(line.capacity))
        }
        clear(&left)
        clear(&right)
    }

    /// Realtime. One stereo frame: read each line's tap, then write the dry
    /// input plus that tap scaled by feedback back in for the next repeat.
    @inline(__always)
    mutating func process(inputLeft: Float, inputRight: Float) -> (Float, Float) {
        let damping = dampingCoefficient
        let wetLeft = readDelayLine(&left, dampingCoefficient: damping)
        let wetRight = readDelayLine(&right, dampingCoefficient: damping)
        writeDelayLine(&left, value: inputLeft + wetLeft * left.feedbackGain)
        writeDelayLine(&right, value: inputRight + wetRight * right.feedbackGain)
        return (wetLeft, wetRight)
    }
}

/// Two `DelayVoiceState`s and the crossfade between them — structurally
/// identical to `ReverbEngine`, because the problem it solves (a preset
/// switch must not reconfigure a buffer still feeding the output) is the
/// same problem with the same solution, just over a simpler voice. See
/// `CrossfadeEngine` for the (shared, generic) implementation.
typealias DelayEngine = CrossfadeEngine<DelayVoiceState>

/// The Sound Field Processor's echo, mixed in after the reverb — a second,
/// independent effect in the same rack unit, both landing on the fully
/// processed signal for the same reason `rackProcessReverb` does: an
/// amplifier-wide send, not a per-source one.
///
/// Bypass is handled once by `rackApplyChain`. The idle/wake handling mirrors
/// `rackProcessReverb` exactly, for the same reason: an echo that is off should
/// cost nothing per sample, and one waking up should start from silence rather
/// than replaying its frozen line contents.
@inline(__always)
func rackProcessDelay(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    rackProcessSend(
        engine: &context.pointee.delay,
        send: &context.pointee.delaySend,
        coefficients: block.pointee.delay,
        smoothing: context.pointee.dsp.smoothingCoefficient,
        buffers: buffers
    )
}

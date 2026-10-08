import CoreAudio
import Darwin

/// One delay line's buffer and the state its feedback path carries between
/// samples. The buffer is allocated once, at its worst-case length; `length`
/// is how much of it the *current* preset actually uses, which is why
/// switching presets never reallocates — it only ever shrinks or grows how
/// far into the same buffer the write pointer wraps.
struct ReverbLineState {
    var buffer: UnsafeMutablePointer<Float>
    let capacity: Int32
    var length: Int32 = 1
    var writeIndex: Int32 = 0
    var dampState: Float = 0
    var feedbackGain: Float = 0
}

/// The pre-delay tap: a plain, non-recirculating line ahead of the network.
struct ReverbPreDelayState {
    var buffer: UnsafeMutablePointer<Float>
    let capacity: Int32
    var length: Int32 = 1
    var writeIndex: Int32 = 0
}

/// Realtime. Reads the sample about to be overwritten — which, because the
/// pointer wraps every `length` writes, is exactly `length` samples old —
/// applies the damping one-pole and the line's own decay gain, in that order.
@inline(__always)
private func readLine(_ line: inout ReverbLineState, dampingCoefficient: Float) -> Float {
    let delayed = line.buffer[Int(line.writeIndex)]
    line.dampState = (1 - dampingCoefficient) * delayed + dampingCoefficient * line.dampState
    return line.dampState * line.feedbackGain
}

@inline(__always)
private func writeLine(_ line: inout ReverbLineState, value: Float) {
    line.buffer[Int(line.writeIndex)] = value
    line.writeIndex += 1
    if line.writeIndex >= line.length { line.writeIndex = 0 }
}

@inline(__always)
private func stepPreDelay(_ state: inout ReverbPreDelayState, input: Float) -> Float {
    let delayed = state.buffer[Int(state.writeIndex)]
    state.buffer[Int(state.writeIndex)] = input
    state.writeIndex += 1
    if state.writeIndex >= state.length { state.writeIndex = 0 }
    return delayed
}

/// One complete reverb network: four lines and a pre-delay tap, per channel.
///
/// A voice is either the crossfade's current target or the one fading out of
/// it — see `ReverbEngine`. Reconfiguring one is always followed by silencing
/// it, which is what makes the crossfade start from nothing rather than from
/// whatever the buffer happened to hold.
struct ReverbVoiceState: CrossfadeVoice {
    typealias Coefficients = ReverbCoefficients
    static var crossfadeSilenceThreshold: Float { Reverb.crossfadeSilenceThreshold }

    var leftLines: (ReverbLineState, ReverbLineState, ReverbLineState, ReverbLineState)
    var rightLines: (ReverbLineState, ReverbLineState, ReverbLineState, ReverbLineState)
    var leftPreDelay: ReverbPreDelayState
    var rightPreDelay: ReverbPreDelayState
    var dampingCoefficient: Float = 0

    /// `ReverbPreset.index` this voice is currently designed for, or −1 for
    /// "never configured" — silent, and safe to repurpose immediately.
    var currentPresetIndex: Int32 = -1

    /// One allocation, at engine start. Every buffer sized to the worst case
    /// across every preset, so no later preset switch ever needs another.
    static func allocate() -> ReverbVoiceState {
        func line(_ index: Int) -> ReverbLineState {
            let capacity = Reverb.maximumLineSamples(forLine: index)
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            return ReverbLineState(buffer: buffer, capacity: Int32(capacity), length: Int32(capacity))
        }
        func preDelay() -> ReverbPreDelayState {
            let capacity = Reverb.maximumPreDelaySamples()
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
            return ReverbPreDelayState(buffer: buffer, capacity: Int32(capacity), length: Int32(capacity))
        }
        return ReverbVoiceState(
            leftLines: (line(0), line(1), line(2), line(3)),
            rightLines: (line(0), line(1), line(2), line(3)),
            leftPreDelay: preDelay(),
            rightPreDelay: preDelay()
        )
    }

    /// The other half of `allocate()`. Called once, at session teardown.
    mutating func free() {
        leftLines.0.buffer.deallocate()
        leftLines.1.buffer.deallocate()
        leftLines.2.buffer.deallocate()
        leftLines.3.buffer.deallocate()
        rightLines.0.buffer.deallocate()
        rightLines.1.buffer.deallocate()
        rightLines.2.buffer.deallocate()
        rightLines.3.buffer.deallocate()
        leftPreDelay.buffer.deallocate()
        rightPreDelay.buffer.deallocate()
    }

    /// Adopt a preset and silence the network for it. Not realtime by
    /// convention rather than necessity — it touches no allocation, but it
    /// is meant to run once, at the instant `ReverbEngine` detects a switch,
    /// not on every buffer.
    mutating func reconfigure(to coefficients: ReverbCoefficients) {
        func apply(_ line: inout ReverbLineState, length: Int32, gain: Float) {
            line.length = min(max(length, 1), line.capacity)
            line.feedbackGain = gain
            line.writeIndex = 0
            line.dampState = 0
            line.buffer.update(repeating: 0, count: Int(line.capacity))
        }
        apply(&leftLines.0, length: coefficients.lineSamplesLeft.0, gain: coefficients.feedbackGains.0)
        apply(&leftLines.1, length: coefficients.lineSamplesLeft.1, gain: coefficients.feedbackGains.1)
        apply(&leftLines.2, length: coefficients.lineSamplesLeft.2, gain: coefficients.feedbackGains.2)
        apply(&leftLines.3, length: coefficients.lineSamplesLeft.3, gain: coefficients.feedbackGains.3)
        apply(&rightLines.0, length: coefficients.lineSamplesRight.0, gain: coefficients.feedbackGains.0)
        apply(&rightLines.1, length: coefficients.lineSamplesRight.1, gain: coefficients.feedbackGains.1)
        apply(&rightLines.2, length: coefficients.lineSamplesRight.2, gain: coefficients.feedbackGains.2)
        apply(&rightLines.3, length: coefficients.lineSamplesRight.3, gain: coefficients.feedbackGains.3)

        let preDelayLength = min(max(coefficients.preDelaySamples, 1), leftPreDelay.capacity)
        leftPreDelay.length = preDelayLength
        leftPreDelay.writeIndex = 0
        leftPreDelay.buffer.update(repeating: 0, count: Int(leftPreDelay.capacity))
        rightPreDelay.length = min(preDelayLength, rightPreDelay.capacity)
        rightPreDelay.writeIndex = 0
        rightPreDelay.buffer.update(repeating: 0, count: Int(rightPreDelay.capacity))

        dampingCoefficient = coefficients.dampingCoefficient
        currentPresetIndex = coefficients.presetIndex
    }

    /// Empty every line and pre-delay tap without touching this voice's preset
    /// configuration — its lengths, feedback gains and damping stay exactly
    /// what they were. Called when the effect wakes from the idle state
    /// `rackProcessReverb` drops it into once it is switched off, so the tail
    /// builds up from silence rather than replaying whatever the buffers
    /// happened to freeze at. A bounded one-shot, run on a user action (the
    /// effect being turned back on), never per buffer — the same class of
    /// audio-thread buffer clear `reconfigure` already performs on a preset
    /// switch.
    mutating func silence() {
        func clear(_ line: inout ReverbLineState) {
            line.writeIndex = 0
            line.dampState = 0
            line.buffer.update(repeating: 0, count: Int(line.capacity))
        }
        clear(&leftLines.0); clear(&leftLines.1); clear(&leftLines.2); clear(&leftLines.3)
        clear(&rightLines.0); clear(&rightLines.1); clear(&rightLines.2); clear(&rightLines.3)
        leftPreDelay.writeIndex = 0
        leftPreDelay.buffer.update(repeating: 0, count: Int(leftPreDelay.capacity))
        rightPreDelay.writeIndex = 0
        rightPreDelay.buffer.update(repeating: 0, count: Int(rightPreDelay.capacity))
    }

    /// Realtime. One stereo frame through this voice's own network — pre-delay,
    /// four damped and decayed line reads, a lossless Hadamard mix, and the
    /// mixed signal (plus the pre-delayed dry input) written back for next time.
    @inline(__always)
    mutating func process(inputLeft: Float, inputRight: Float) -> (Float, Float) {
        let damping = dampingCoefficient
        let wetLeft = processReverbChannel(
            input: inputLeft, lines: &leftLines, preDelay: &leftPreDelay, dampingCoefficient: damping
        )
        let wetRight = processReverbChannel(
            input: inputRight, lines: &rightLines, preDelay: &rightPreDelay, dampingCoefficient: damping
        )
        return (wetLeft, wetRight)
    }
}

/// Realtime. One channel's one frame through its four lines and pre-delay.
///
/// A free function rather than a method on `ReverbVoiceState`: a mutating
/// method already requires exclusive access to the whole of `self` for its
/// dispatch, which conflicts with also passing another of its own stored
/// properties in as an explicit `inout` argument — Swift's exclusivity
/// checker rejects that overlap outright. Free of a `self` to be exclusive
/// about, this has no such conflict.
@inline(__always)
private func processReverbChannel(
    input: Float,
    lines: inout (ReverbLineState, ReverbLineState, ReverbLineState, ReverbLineState),
    preDelay: inout ReverbPreDelayState,
    dampingCoefficient: Float
) -> Float {
    let preDelayed = stepPreDelay(&preDelay, input: input)

    let damping = dampingCoefficient
    let d0 = readLine(&lines.0, dampingCoefficient: damping)
    let d1 = readLine(&lines.1, dampingCoefficient: damping)
    let d2 = readLine(&lines.2, dampingCoefficient: damping)
    let d3 = readLine(&lines.3, dampingCoefficient: damping)

    let (m0, m1, m2, m3) = Reverb.hadamardMix(d0, d1, d2, d3)

    writeLine(&lines.0, value: preDelayed + m0)
    writeLine(&lines.1, value: preDelayed + m1)
    writeLine(&lines.2, value: preDelayed + m2)
    writeLine(&lines.3, value: preDelayed + m3)

    // Averaged rather than summed: four lines' worth of decayed energy
    // adding in phase at the moment of an impulse would otherwise nearly
    // quadruple the level the wet/dry mix has to work with.
    return (d0 + d1 + d2 + d3) * 0.25
}

/// Two `ReverbVoiceState`s and the crossfade between them — see
/// `CrossfadeEngine` for the (shared, generic) implementation.
typealias ReverbEngine = CrossfadeEngine<ReverbVoiceState>

/// Run the Sound Field Processor's reverb over the output buffers and mix it
/// back in.
///
/// Deliberately a separate pass over the fully-filtered, fully-gained signal
/// `rackProcess` just produced, rather than another stage threaded through
/// `rackProcessChannel`: the reverb needs a channel's *partner* on every
/// sample — a stereo effect, not a per-channel filter — and mixing it in
/// after volume and balance means turning the system down turns the reverb's
/// send down with it, which is the behaviour wanted from an amplifier-wide
/// effect rather than a per-source one.
///
/// Bypass is handled once by `rackApplyChain`, for the same reason it always
/// was: a fault in parameter compilation must never mean silence, and the
/// panic path must never depend on this pass having run.
@inline(__always)
func rackProcessReverb(
    context: UnsafeMutablePointer<TapRenderContext>,
    block: UnsafeMutablePointer<DSPBlock>,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    rackProcessSend(
        engine: &context.pointee.reverb,
        send: &context.pointee.reverbSend,
        coefficients: block.pointee.reverb,
        smoothing: context.pointee.dsp.smoothingCoefficient,
        buffers: buffers
    )
}

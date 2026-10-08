import CoreAudio
import Darwin

/// Two defences against the one failure mode microphone monitoring can produce
/// on its own: the mic hears the speakers, which makes the speakers louder,
/// which makes the mic louder.
///
/// They are deliberately different in kind, because they answer different
/// questions. `FeedbackRisk` asks *can a loop exist at all* — which macOS will
/// usually tell us outright — and the answer removes the problem rather than
/// surviving it. `FeedbackGuard` asks *is one starting right now*, for the
/// outputs nothing can classify: an unknown USB interface, a Bluetooth speaker,
/// a monitor with speakers built in.
///
/// The limiter at the end of the chain is not a third defence. It bounds how
/// loud a howl gets and does nothing whatever to stop one.
// MARK: - Can a loop exist?

/// Whether monitoring a microphone into a given output can feed back.
public enum FeedbackRisk: Equatable, Sendable {
    /// Headphones. Whatever leaks out of them is far below what it takes to
    /// close a loop, so the monitor runs unguarded.
    case none

    /// A loudspeaker, in the same room as the microphone by construction —
    /// they are both attached to this Mac.
    case loudspeaker

    /// Cannot be told apart. An external interface may be feeding studio
    /// monitors or a headphone amplifier and reports the same thing either
    /// way; a Bluetooth output may be earbuds or a speaker.
    ///
    /// Deliberately *not* treated as dangerous. Blocking every USB DAC and
    /// every pair of AirPods to catch the Bluetooth speaker would make the
    /// feature useless far more often than it would save anyone, so these are
    /// left to `FeedbackGuard` below, which does not have to guess in advance.
    case unknown

    /// `kAudioDevicePropertyDataSource` four-character codes. Measured on real
    /// hardware rather than taken from a header — Core Audio documents the
    /// property but not the vocabulary of its values.
    ///
    /// | | |
    /// |---|---|
    /// | `hdpn` | External Headphones |
    /// | `ispk` | MacBook Air Speakers |
    /// | `imic` | MacBook Air Microphone |
    /// | `emic` | External Microphone |
    enum DataSource {
        static let headphones: UInt32 = 0x6864_706E  // 'hdpn'
        static let internalSpeaker: UInt32 = 0x6973_706B  // 'ispk'
        static let externalSpeaker: UInt32 = 0x6573_706B  // 'espk'
    }

    /// Classify an output from what the device reports about itself.
    ///
    /// Pure, and separated from the Core Audio read that feeds it, for the same
    /// reason `DeviceChangeDecision.decide` is: the rule is the whole of what
    /// has to be right, and it should be checkable without plugging anything
    /// in.
    ///
    /// - Parameter dataSource: `kAudioDevicePropertyDataSource` in the output
    ///   scope, or nil for a device that has no such property — which most
    ///   external interfaces do not.
    static func decide(dataSource: UInt32?) -> FeedbackRisk {
        switch dataSource {
        case DataSource.headphones: .none
        case DataSource.internalSpeaker, DataSource.externalSpeaker: .loudspeaker
        default: .unknown
        }
    }
}

// MARK: - Is a loop starting?

/// The howl detector's tuning, and the reasoning behind each number.
///
/// It watches the microphone's own signal, before its gain is applied, which
/// is what closes the loop properly: ducking lowers what the speakers emit,
/// which lowers what the mic hears, which the very next buffer measures.
///
/// Three conditions have to hold together, and the conjunction is the whole
/// design — any one of them alone fires on ordinary speech.
public enum FeedbackGuard {
    /// Below this the microphone is effectively silent and nothing it does is
    /// worth chasing. Room tone can drift upward by a good margin in relative
    /// terms while remaining inaudible.
    public static let floorDecibels: Float = -45

    /// How far the fast envelope must sit above the slow one to count as
    /// *growing*: +4 dB. Feedback grows exponentially and does not stop; the
    /// slow envelope cannot keep up with it, so the ratio opens and stays
    /// open. Speech opens it too, on every syllable — and closes it again,
    /// which is what `triggerBuffers` below is for.
    public static let growthRatio: Float = 1.6

    /// Peak over RMS. A sustained howl collapses toward a pure tone, whose
    /// crest factor is √2 ≈ 1.41 and stays there. Speech runs 3–10 and music
    /// higher still, so this is the condition that actually separates a howl
    /// from someone talking loudly, rather than merely delaying the response to
    /// them.
    public static let maximumCrestFactor: Float = 2.2

    /// Consecutive suspicious buffers before ducking — around 30 ms at the
    /// buffer sizes Core Audio delivers. A plosive can look tonal and growing
    /// for one buffer; nothing but feedback does it for four in a row, and
    /// feedback takes far longer than 30 ms to become loud.
    public static let triggerBuffers: Int32 = 4

    /// How hard each trigger cuts: −10 dB, applied to whatever the gain
    /// already is. Compounding is deliberate — a loop with a lot of gain in it
    /// simply triggers again on the next buffer and is cut again, so the
    /// response scales itself to the severity rather than needing a single
    /// number that is right for every room.
    public static let duckFactor: Float = 0.3

    /// The floor of the cut, −34 dB. Not zero: silence would be
    /// indistinguishable from the monitor being broken, and a trickle is
    /// enough for the detector to keep watching whether the room has settled.
    public static let minimumDuckGain: Float = 0.02

    /// How long the cut is held before recovery starts. Long enough for a room
    /// to stop ringing, short enough not to swallow the sentence after it.
    public static let holdSeconds: Float = 0.75

    /// Time constant for coming back up. Slow, and much slower than the cut:
    /// this is the same asymmetry every compressor uses, and for the same
    /// reason — a fast recovery into a loop that is still there just produces
    /// a stutter of howls.
    public static let recoverySeconds: Float = 1.5

    /// Envelope time constants. The fast one has to track a howl building; the
    /// slow one is the reference it is measured against, and must be long
    /// enough that it does not simply follow the howl up.
    public static let fastEnvelopeSeconds: Float = 0.03
    public static let slowEnvelopeSeconds: Float = 0.8

    /// Where recovery stops chasing and snaps to exactly unity: −0.09 dB,
    /// comfortably inaudible.
    ///
    /// A one-pole approaches its target and never arrives, so without this the
    /// gain would settle a hair under 1 and stay there for the rest of the
    /// session — the microphone permanently a fraction of a decibel down, and
    /// "not ducking" never quite true. The same reason
    /// `rackProcessCompressor` snaps its own remnant to zero rather than
    /// multiplying by 0.9999 forever.
    public static let recoveredThreshold: Float = 0.99
}

/// One guard setting, compiled for a sample rate. Plain old data — what the
/// realtime path reads, never what it computes.
struct FeedbackCoefficients {
    /// Folded from the user's switch and from whether there is a microphone in
    /// the aggregate at all, so the realtime path reads one flag.
    var isActive: Bool = false

    /// Which input stream carries the microphone, or −1 for none. Named
    /// explicitly rather than inferred from a buffer being mono: an
    /// application playing mono audio hits that same branch, and ducking one
    /// of those because a *different* source is howling would be a bug that
    /// only shows up on somebody else's machine.
    var micStream: Int32 = -1

    var sampleRate: Float = 48_000

    /// `floorDecibels` as a linear amplitude, so the realtime comparison is
    /// against the RMS it already has rather than a `log10f` per buffer.
    var floorAmplitude: Float = 0

    static func compile(
        isEnabled: Bool,
        micStreamIndex: Int?,
        sampleRate: Double
    ) -> FeedbackCoefficients {
        var coefficients = FeedbackCoefficients()
        coefficients.isActive = isEnabled && micStreamIndex != nil
        coefficients.micStream = micStreamIndex.map(Int32.init) ?? -1
        coefficients.sampleRate = Float(sampleRate > 0 ? sampleRate : 48_000)
        coefficients.floorAmplitude = powf(10, FeedbackGuard.floorDecibels / 20)
        return coefficients
    }
}

/// The detector's running state. Audio thread only, like every other envelope
/// in `TapRenderContext`.
struct FeedbackGuardState {
    var fastEnvelope: Float = 0
    var slowEnvelope: Float = 0

    /// What the microphone's gain is currently multiplied by. 1 is untouched,
    /// and is where this sits for any room that never howls.
    var duckGain: Float = 1

    /// Consecutive suspicious buffers so far.
    var suspicion: Int32 = 0

    /// Seconds of hold left before recovery may begin.
    var holdRemaining: Float = 0

    mutating func reset() {
        fastEnvelope = 0
        slowEnvelope = 0
        duckGain = 1
        suspicion = 0
        holdRemaining = 0
    }
}

// MARK: - Realtime

/// One-pole coefficient for a step of `elapsed` seconds toward a time constant
/// of `tau`.
///
/// Per *buffer* rather than per sample, which is what makes the handful of
/// `expf` calls here free next to the `log10f` the compressor spends on every
/// sample. It also means the detector behaves identically whatever buffer size
/// the device hands us, rather than being tuned for one and wrong on another.
@inline(__always)
func rackFeedbackCoefficient(elapsed: Float, tau: Float) -> Float {
    guard elapsed > 0, tau > 0 else { return 1 }
    return 1 - expf(-elapsed / tau)
}

/// Advance the detector by one buffer's worth of microphone signal and return
/// the gain the microphone should now be multiplied by.
///
/// Split out from the buffer walk, and pure apart from the state it is handed,
/// so the behaviour that matters can be tested directly: that a rising tone is
/// caught, that speech is not, and that a quiet room is left alone. Those are
/// properties of this function, not of how the mix loop is written.
///
/// - Parameters:
///   - rms: root-mean-square of this buffer's microphone samples, pre-gain.
///   - peak: the largest absolute sample in the same buffer.
///   - elapsed: the buffer's duration in seconds.
@inline(__always)
func rackFeedbackDuck(
    state: inout FeedbackGuardState,
    coefficients: FeedbackCoefficients,
    rms: Float,
    peak: Float,
    elapsed: Float
) -> Float {
    guard coefficients.isActive else {
        state.reset()
        return 1
    }

    let fast = rackFeedbackCoefficient(
        elapsed: elapsed, tau: FeedbackGuard.fastEnvelopeSeconds
    )
    let slow = rackFeedbackCoefficient(
        elapsed: elapsed, tau: FeedbackGuard.slowEnvelopeSeconds
    )
    state.fastEnvelope += (rms - state.fastEnvelope) * fast
    state.slowEnvelope += (rms - state.slowEnvelope) * slow

    // A howl is loud, growing, and tonal — all three at once. Any one of them
    // on its own describes ordinary speech just as well.
    let isLoudEnough = state.fastEnvelope > coefficients.floorAmplitude
    let isGrowing = state.fastEnvelope > state.slowEnvelope * FeedbackGuard.growthRatio
    let crest = rms > 0 ? peak / rms : .greatestFiniteMagnitude
    let isTonal = crest < FeedbackGuard.maximumCrestFactor

    if isLoudEnough, isGrowing, isTonal {
        state.suspicion += 1
    } else if state.suspicion > 0 {
        // Decay rather than reset. A howl building through a buffer that
        // happens to look untidy is still a howl, and starting the count again
        // from zero each time would let a marginal one climb indefinitely.
        state.suspicion -= 1
    }

    if state.suspicion >= FeedbackGuard.triggerBuffers {
        state.duckGain = max(
            state.duckGain * FeedbackGuard.duckFactor, FeedbackGuard.minimumDuckGain
        )
        state.holdRemaining = FeedbackGuard.holdSeconds
        state.suspicion = 0
        return state.duckGain
    }

    if state.holdRemaining > 0 {
        state.holdRemaining = max(state.holdRemaining - elapsed, 0)
        return state.duckGain
    }

    if state.duckGain < 1 {
        let recover = rackFeedbackCoefficient(
            elapsed: elapsed, tau: FeedbackGuard.recoverySeconds
        )
        state.duckGain = min(state.duckGain + (1 - state.duckGain) * recover, 1)
        if state.duckGain > FeedbackGuard.recoveredThreshold {
            state.duckGain = 1
        }
    }
    return state.duckGain
}

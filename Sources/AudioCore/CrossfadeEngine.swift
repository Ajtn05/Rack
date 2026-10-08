import CoreAudio

/// A published coefficients type that carries the preset index a
/// `CrossfadeVoice` was last configured for — how `CrossfadeEngine` decides
/// whether the target voice is still current.
protocol CrossfadeCoefficients {
    var presetIndex: Int32 { get }

    /// Equal-power wet/dry, already folding in the effect's enabled flag —
    /// disabled is `wetGain` 0, `dryGain` 1, exactly as if the wet amount
    /// were zero.
    var wetGain: Float { get }
    var dryGain: Float { get }
}

/// One effect's realtime voice — a delay line, an FDN, or anything else that
/// can be reconfigured for a new preset and silenced. `CrossfadeEngine` holds
/// two of these and crossfades between them so a preset switch never
/// reconfigures a buffer still feeding the output.
protocol CrossfadeVoice {
    associatedtype Coefficients: CrossfadeCoefficients

    /// This voice's preset index, or −1 for "never configured" — silent, and
    /// safe to repurpose immediately.
    var currentPresetIndex: Int32 { get }

    /// Below this weight a fading voice is inaudible, so it is safe to
    /// reconfigure and safe to stop mixing in.
    static var crossfadeSilenceThreshold: Float { get }

    static func allocate() -> Self
    mutating func free()
    mutating func reconfigure(to coefficients: Coefficients)
    mutating func silence()
    mutating func process(inputLeft: Float, inputRight: Float) -> (Float, Float)
}

/// Two `CrossfadeVoice`s and the crossfade between them.
///
/// Only one voice is ever the *target* — what the currently selected preset
/// actually is. The other is either silent (nothing to process, and skipped)
/// or fading out of a switch that has not finished yet. Both are permanently
/// allocated; a preset change only ever reconfigures whichever one is not
/// currently audible, so no switch — however fast a run of them arrives —
/// ever touches a buffer that is still contributing to the output.
///
/// Generic over the voice rather than duplicated per effect: the crossfade
/// machinery (this type) is identical for every stateful effect in the
/// chain; only the voice itself — an FDN with pre-delay for reverb, a single
/// line for delay — differs. Used only within this module, always at a
/// concrete `Voice` (see the `ReverbEngine`/`DelayEngine` typealiases), so
/// whole-module optimization specializes every use — verified by inspecting
/// the release build for `CrossfadeEngine`'s absence from the generic
/// witness table, not assumed.
struct CrossfadeEngine<Voice: CrossfadeVoice> {
    var voiceA: Voice
    var voiceB: Voice
    var targetIsA: Bool = true

    /// Weight of the target voice in the mix; the other one gets `1 -
    /// crossfadeGain`. Starts at 1 so the very first preset a session ever
    /// selects plays at full weight immediately — there is no prior voice to
    /// fade out of, so there is nothing a fade would be protecting against.
    var crossfadeGain: Float = 1

    static func allocate() -> CrossfadeEngine {
        CrossfadeEngine(voiceA: .allocate(), voiceB: .allocate())
    }

    mutating func free() {
        voiceA.free()
        voiceB.free()
    }

    /// Empty both voices and cancel any crossfade in progress, so the next
    /// frame processed starts from silence on the current target voice.
    mutating func silence() {
        voiceA.silence()
        voiceB.silence()
        crossfadeGain = 1
    }

    /// A rate change is a discontinuity, not a preset switch. Install the new
    /// timing immediately, with no old-rate voice contributing to the mix.
    mutating func reset(to coefficients: Voice.Coefficients) {
        voiceA.reconfigure(to: coefficients)
        voiceB.silence()
        targetIsA = true
        crossfadeGain = 1
    }

    /// Realtime. Returns the wet signal only — dry/wet mixing is the
    /// caller's job, the same separation `DSPBlock` keeps between filtering
    /// and gain.
    @inline(__always)
    mutating func process(
        inputLeft: Float,
        inputRight: Float,
        coefficients: Voice.Coefficients,
        crossfadeCoefficient: Float
    ) -> (Float, Float) {
        let targetPresetIndex = targetIsA ? voiceA.currentPresetIndex : voiceB.currentPresetIndex
        let otherWeight = 1 - crossfadeGain

        // A switch is only ever actioned once the voice it would repurpose
        // has already faded to inaudibility. Requesting a second preset
        // before the first crossfade finishes does not interrupt it — the
        // new request simply waits, and is picked up, still current,
        // the moment it becomes safe.
        if coefficients.presetIndex != targetPresetIndex,
           otherWeight <= Voice.crossfadeSilenceThreshold {
            targetIsA.toggle()
            if targetIsA {
                voiceA.reconfigure(to: coefficients)
            } else {
                voiceB.reconfigure(to: coefficients)
            }
            // The voice that was the target a moment ago keeps the weight it
            // already had; flipping what this variable names, rather than
            // resetting it, is what keeps a rapid run of switches click-free.
            crossfadeGain = 1 - crossfadeGain
        }

        crossfadeGain = rackSmooth(crossfadeGain, toward: 1, coefficient: crossfadeCoefficient)
        let targetWeight = crossfadeGain
        let fadingWeight = 1 - crossfadeGain

        let (targetLeft, targetRight) = targetIsA
            ? voiceA.process(inputLeft: inputLeft, inputRight: inputRight)
            : voiceB.process(inputLeft: inputLeft, inputRight: inputRight)

        guard fadingWeight > Voice.crossfadeSilenceThreshold else {
            return (targetLeft * targetWeight, targetRight * targetWeight)
        }

        let (fadingLeft, fadingRight) = targetIsA
            ? voiceB.process(inputLeft: inputLeft, inputRight: inputRight)
            : voiceA.process(inputLeft: inputLeft, inputRight: inputRight)

        return (
            targetLeft * targetWeight + fadingLeft * fadingWeight,
            targetRight * targetWeight + fadingRight * fadingWeight
        )
    }
}

/// The wet/dry send state for one effect mixed into the chain: smoothed
/// gains for its own mix knob, whether it is currently doing per-sample
/// work, and the one-pole coefficient for its preset crossfade. Distinct
/// from the crossfade inside `CrossfadeEngine` — that smooths a voice being
/// swapped out; this smooths a mix knob moving.
struct WetDrySendState {
    var wetGain: Float = 0
    var dryGain: Float = 1
    var isActive = false
    var crossfadeCoefficient: Float = 0
}

/// Mix one `CrossfadeEngine`-backed effect into every stereo pair in
/// `buffers`, at the smoothed wet/dry balance `send` describes. Shared by
/// every effect built on `CrossfadeEngine` — today reverb and delay — so a
/// stateful send only has to be gotten right once.
///
/// Idle handling: `wetGain == 0` is the effect contributing nothing —
/// switched off, or fully dry — and there `dryGain` is exactly 1, so the mix
/// below is passthrough. Once it has faded to that and gone idle, the voices
/// are not stepped at all until the effect is switched back on; waking it
/// clears their frozen state first (`CrossfadeEngine.silence()`) so the tail
/// builds from silence rather than replaying whatever they held when it went
/// quiet.
@inline(__always)
func rackProcessSend<Voice: CrossfadeVoice>(
    engine: inout CrossfadeEngine<Voice>,
    send: inout WetDrySendState,
    coefficients: Voice.Coefficients,
    smoothing: Float,
    buffers: UnsafeMutableAudioBufferListPointer
) {
    let isNoOp = coefficients.wetGain == 0
    if isNoOp, !send.isActive { return }
    if !send.isActive {
        engine.silence()
        send.isActive = true
    }

    let crossfadeCoefficient = send.crossfadeCoefficient

    @inline(__always)
    func mix(left: inout Float, right: inout Float) {
        send.wetGain = rackSmooth(send.wetGain, toward: coefficients.wetGain, coefficient: smoothing)
        send.dryGain = rackSmooth(send.dryGain, toward: coefficients.dryGain, coefficient: smoothing)
        let (wetLeft, wetRight) = engine.process(
            inputLeft: left, inputRight: right,
            coefficients: coefficients, crossfadeCoefficient: crossfadeCoefficient
        )
        let wet = send.wetGain
        let dry = send.dryGain
        left = left * dry + wetLeft * wet
        right = right * dry + wetRight * wet
    }

    rackWalkStereoPairs(buffers: buffers, mix)

    // Faded out: go idle so later buffers skip the network entirely. The wet
    // mix has reached silence and the dry has returned to unity — what is
    // left is passthrough, nothing the network could still add.
    if isNoOp,
       send.wetGain <= Voice.crossfadeSilenceThreshold,
       send.dryGain >= 1 - Voice.crossfadeSilenceThreshold {
        send.isActive = false
    }
}

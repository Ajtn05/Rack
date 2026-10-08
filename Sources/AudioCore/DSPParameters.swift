import Darwin

/// Everything the user can set, as one immutable value.
///
/// This is the whole of the engine's tunable state. Keeping it in a single
/// `Equatable`, `Codable` value is what makes Phase 5 trivial — a preset is
/// this plus a name — and what makes the handoff to the audio thread a single
/// atomic publication rather than a dozen racing writes.
public struct DSPParameters: Equatable, Sendable, Codable {
    /// Output trim, ±12 dB. Cutting here is how you make room for EQ boost
    /// without clipping.
    public var preampDecibels: Double

    /// One entry per band of `EQBank`, each ±12 dB.
    public var bandGains: [Double]

    /// −1 hard left, 0 centre, +1 hard right.
    public var balance: Double

    /// Depth of the boost contour, 0 to +12 dB. Not a toggle: the depth is
    /// the maximum bass lift the contour reaches once the volume control has
    /// pulled the signal down far enough — see `boostBassDecibels`.
    public var boostDepthDecibels: Double

    /// Bass shelf of the tone control, ±12 dB, corner at `toneBassFrequency`.
    /// Separate from the graphic EQ and from `boostDepthDecibels`.
    public var toneBassDecibels: Double

    /// Treble shelf of the tone control, ±12 dB, corner at
    /// `toneTrebleFrequency`.
    public var toneTrebleDecibels: Double

    /// `TONE DEFEAT`. Bypasses both tone shelves without zeroing
    /// `toneBassDecibels` / `toneTrebleDecibels` — the knobs keep their
    /// position and pick up exactly where they were left once defeat is
    /// lifted.
    public var isToneDefeated: Bool

    /// Whether the output stage automatically cuts to keep the combined
    /// response's peak gain from raising the level that leaves the engine.
    /// Defeatable for anyone who wants the raw gain — see
    /// `headroomCompensationDecibels(sampleRate:)`.
    public var isHeadroomCompensationEnabled: Bool

    /// Drive into the tape/tube saturator, 0…24 dB.
    public var saturationDriveDecibels: Double

    /// Dry/wet blend of the saturated signal, 0…1. Defaults to 0 — the same
    /// "the effect adds nothing until both this and the enable switch say
    /// otherwise" convention `reverbWetAmount` uses.
    public var saturationMixAmount: Double

    /// Master bypass for saturation, independent of drive and mix — the same
    /// "the effect defaults to off" convention every other effect in the
    /// chain gets.
    public var isSaturationEnabled: Bool

    /// Level above which the compressor starts reducing gain, in dBFS.
    public var compressorThresholdDecibels: Double

    /// How hard it reduces above threshold — 1:1 is no compression, higher
    /// numbers flatten the signal more aggressively toward the threshold.
    public var compressorRatio: Double

    /// How fast gain reduction engages once the signal crosses threshold.
    public var compressorAttackMilliseconds: Double

    /// How fast gain reduction relaxes once the signal falls back under it.
    public var compressorReleaseMilliseconds: Double

    /// Gain added back after compression, to compensate for the level the
    /// ratio took away. Manual rather than automatic — the amount a
    /// compressor "should" add back is a judgement call this leaves to
    /// whoever is listening, the same way every other gain stage here does.
    public var compressorMakeupDecibels: Double

    /// Master bypass, independent of every knob above — the same "the
    /// effect defaults to off" convention `isReverbEnabled` and
    /// `isDelayEnabled` use.
    public var isCompressorEnabled: Bool

    /// The Sound Field Processor's named space.
    public var reverbPreset: ReverbPreset

    /// Wet amount, 0…1. Defaults to 0 — the effect adds nothing to the mix
    /// until both this and `isReverbEnabled` say otherwise.
    public var reverbWetAmount: Double

    /// Master bypass for the reverb, independent of the wet amount above —
    /// the reverb "effect defaults to off" as its own switch, the same as
    /// every other effect in the chain gets one.
    public var isReverbEnabled: Bool

    /// The Sound Field Processor's named echo — a second, independent
    /// effect alongside the reverb.
    public var delayPreset: DelayPreset

    /// Wet amount, 0…1. Same "defaults to nothing until both this and the
    /// enable switch say otherwise" convention as `reverbWetAmount`.
    public var delayWetAmount: Double

    /// Master bypass for the delay, independent of `isReverbEnabled` — the
    /// two effects are switched on and off separately.
    public var isDelayEnabled: Bool

    /// Stereo width, 0…2. 1 is unity (no change); 0 collapses to mono;
    /// above 1 widens past what a single hard-panned channel is calibrated
    /// to, the same energy-preserving rotation `EngineController`'s
    /// goniometer transform uses for exactly that reason.
    public var stereoWidth: Double

    /// Headphone crossfeed amount, 0…1 — see `Crossfeed`.
    public var crossfeedAmount: Double

    /// Master bypass for crossfeed, independent of the amount above — the
    /// same "the effect defaults to off" convention every other effect in
    /// the chain gets.
    public var isCrossfeedEnabled: Bool

    /// Where the limiter holds the output, in dBFS — see `Limiter`.
    public var limiterCeilingDecibels: Double

    /// How quickly the limiter lets go after a peak, in milliseconds.
    public var limiterReleaseMilliseconds: Double

    /// Whether the limiter is in circuit. **Defaults to on**, unlike every
    /// other switch in this file, and for a reason that is not stylistic: this
    /// is not an effect, it is the guard rail that stops the rest of the chain
    /// handing the DAC something past full scale. An effect that is off by
    /// default costs the user a feature they have not found yet; a *safety
    /// device* that is off by default costs them the one thing it was there to
    /// prevent, at the moment it was needed. Defeatable for anyone who wants
    /// the raw output, the same way headroom compensation is.
    ///
    /// It stays bit-transparent below the ceiling regardless: the gain is
    /// exactly 1 until a sample actually exceeds it.
    public var isLimiterEnabled: Bool

    /// Rack's own output level, 0…1. A real attenuator: it scales what leaves
    /// the engine, and the boost contour compensates as it comes down.
    ///
    /// Independent of the system volume, which Rack does not touch. Two
    /// volume controls in series is not ideal, but the alternative — reading
    /// and following the hardware's own control — is Phase 3 work, and until
    /// then a slider labelled Volume has to actually change the volume.
    public var volume: Double

    /// Hard bypass. Routes audio through untouched.
    public var isBypassed: Bool

    public static let flat = DSPParameters()

    public init(
        preampDecibels: Double = 0,
        bandGains: [Double] = Array(repeating: 0, count: EQBank.bandCount),
        balance: Double = 0,
        boostDepthDecibels: Double = 0,
        toneBassDecibels: Double = 0,
        toneTrebleDecibels: Double = 0,
        isToneDefeated: Bool = false,
        isHeadroomCompensationEnabled: Bool = true,
        saturationDriveDecibels: Double = 0,
        saturationMixAmount: Double = 0,
        isSaturationEnabled: Bool = false,
        compressorThresholdDecibels: Double = -18,
        compressorRatio: Double = 4,
        compressorAttackMilliseconds: Double = 10,
        compressorReleaseMilliseconds: Double = 100,
        compressorMakeupDecibels: Double = 0,
        isCompressorEnabled: Bool = false,
        reverbPreset: ReverbPreset = .hall,
        reverbWetAmount: Double = 0,
        isReverbEnabled: Bool = false,
        delayPreset: DelayPreset = .echo,
        delayWetAmount: Double = 0,
        isDelayEnabled: Bool = false,
        stereoWidth: Double = 1,
        crossfeedAmount: Double = 0,
        isCrossfeedEnabled: Bool = false,
        limiterCeilingDecibels: Double = Limiter.defaultCeilingDecibels,
        limiterReleaseMilliseconds: Double = Limiter.defaultReleaseMilliseconds,
        isLimiterEnabled: Bool = true,
        volume: Double = 1,
        isBypassed: Bool = false
    ) {
        self.preampDecibels = preampDecibels
        self.bandGains = bandGains
        self.balance = balance
        self.boostDepthDecibels = boostDepthDecibels
        self.toneBassDecibels = toneBassDecibels
        self.toneTrebleDecibels = toneTrebleDecibels
        self.isToneDefeated = isToneDefeated
        self.isHeadroomCompensationEnabled = isHeadroomCompensationEnabled
        self.saturationDriveDecibels = saturationDriveDecibels
        self.saturationMixAmount = saturationMixAmount
        self.isSaturationEnabled = isSaturationEnabled
        self.compressorThresholdDecibels = compressorThresholdDecibels
        self.compressorRatio = compressorRatio
        self.compressorAttackMilliseconds = compressorAttackMilliseconds
        self.compressorReleaseMilliseconds = compressorReleaseMilliseconds
        self.compressorMakeupDecibels = compressorMakeupDecibels
        self.isCompressorEnabled = isCompressorEnabled
        self.reverbPreset = reverbPreset
        self.reverbWetAmount = reverbWetAmount
        self.isReverbEnabled = isReverbEnabled
        self.delayPreset = delayPreset
        self.delayWetAmount = delayWetAmount
        self.isDelayEnabled = isDelayEnabled
        self.stereoWidth = stereoWidth
        self.crossfeedAmount = crossfeedAmount
        self.isCrossfeedEnabled = isCrossfeedEnabled
        self.limiterCeilingDecibels = limiterCeilingDecibels
        self.limiterReleaseMilliseconds = limiterReleaseMilliseconds
        self.isLimiterEnabled = isLimiterEnabled
        self.volume = volume
        self.isBypassed = isBypassed
    }

    /// Clamp everything into range and fix the band count.
    ///
    /// Applied before compiling rather than trusted, because these values
    /// arrive from a JSON file a user may have edited by hand (Phase 5) as
    /// well as from sliders that cannot go out of range.
    public func normalised() -> DSPParameters {
        var copy = self
        copy.preampDecibels = Self.clamp(preampDecibels, to: EQBank.maximumGainDecibels)
        copy.balance = Self.clamp(balance, to: 1)
        copy.boostDepthDecibels = Self.clampUnipolar(
            boostDepthDecibels, to: Self.boostMaximumDepthDecibels
        )
        copy.toneBassDecibels = Self.clamp(toneBassDecibels, to: Self.toneMaximumDecibels)
        copy.toneTrebleDecibels = Self.clamp(toneTrebleDecibels, to: Self.toneMaximumDecibels)
        copy.saturationDriveDecibels = Self.clampRange(
            saturationDriveDecibels, to: Saturation.driveRangeDecibels
        )
        copy.saturationMixAmount = Self.clampUnipolar(saturationMixAmount, to: Saturation.mixRange.upperBound)
        copy.reverbWetAmount = Self.clampUnipolar(reverbWetAmount, to: 1)
        copy.delayWetAmount = Self.clampUnipolar(delayWetAmount, to: 1)
        copy.stereoWidth = min(max(stereoWidth.isFinite ? stereoWidth : 1, 0), 2)
        copy.crossfeedAmount = Self.clampUnipolar(crossfeedAmount, to: Crossfeed.amountRange.upperBound)
        copy.limiterCeilingDecibels = min(
            max(limiterCeilingDecibels.isFinite ? limiterCeilingDecibels : Limiter.defaultCeilingDecibels,
                Limiter.ceilingRangeDecibels.lowerBound),
            Limiter.ceilingRangeDecibels.upperBound
        )
        copy.limiterReleaseMilliseconds = min(
            max(limiterReleaseMilliseconds.isFinite ? limiterReleaseMilliseconds : Limiter.defaultReleaseMilliseconds,
                Limiter.releaseRangeMilliseconds.lowerBound),
            Limiter.releaseRangeMilliseconds.upperBound
        )
        copy.compressorThresholdDecibels = Self.clampRange(
            compressorThresholdDecibels, to: Compressor.thresholdRangeDecibels
        )
        copy.compressorRatio = Self.clampRange(compressorRatio, to: Compressor.ratioRange)
        copy.compressorAttackMilliseconds = Self.clampRange(
            compressorAttackMilliseconds, to: Compressor.attackRangeMilliseconds
        )
        copy.compressorReleaseMilliseconds = Self.clampRange(
            compressorReleaseMilliseconds, to: Compressor.releaseRangeMilliseconds
        )
        copy.compressorMakeupDecibels = Self.clampRange(
            compressorMakeupDecibels, to: Compressor.makeupRangeDecibels
        )
        copy.volume = min(max(volume, 0), 1)

        var gains = bandGains.map { Self.clamp($0, to: EQBank.maximumGainDecibels) }
        if gains.count < EQBank.bandCount {
            gains += Array(repeating: 0, count: EQBank.bandCount - gains.count)
        } else if gains.count > EQBank.bandCount {
            gains = Array(gains.prefix(EQBank.bandCount))
        }
        copy.bandGains = gains
        return copy
    }

    private static func clamp(_ value: Double, to limit: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -limit), limit)
    }

    private static func clampUnipolar(_ value: Double, to limit: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), limit)
    }

    /// Clamps to an arbitrary, not-necessarily-symmetric range — the
    /// compressor's own controls, unlike everything above, are not centred
    /// on zero.
    private static func clampRange(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Derived values

    /// Linear gain for the preamp.
    public var preampGain: Double { pow(10, preampDecibels / 20) }

    /// Attenuation range of the volume control, in dB below unity.
    ///
    /// 48 dB is quiet enough to be a usable minimum and shallow enough that
    /// the useful part of the travel is not squeezed into the top fifth.
    public static let volumeRangeDecibels: Double = 48

    /// The volume control's setting expressed as attenuation.
    ///
    /// **dB-linear**, which is the taper a volume control wants and the one a
    /// number beside it can honestly describe: each equal step of travel is an
    /// equal number of decibels, so the reading and the loudness move together.
    ///
    /// The first attempt used a square law. That is an audio taper of a sort,
    /// but the dB it produces are not linear in the travel, so the knob
    /// position and any number shown next to it disagree — which is exactly
    /// how it read on screen.
    public var volumeDecibels: Double {
        guard volume > 0 else { return -.infinity }
        let clamped = min(max(volume, 0), 1)
        return -Self.volumeRangeDecibels * (1 - clamped)
    }

    /// Linear gain for the volume control.
    public var volumeGain: Double {
        let decibels = volumeDecibels
        guard decibels > -.infinity else { return 0 }
        return pow(10, decibels / 20)
    }

    /// The volume setting as a string for a readout. `−∞` at the bottom,
    /// because that is what silence is.
    public var volumeDisplay: String {
        let decibels = volumeDecibels
        guard decibels > -.infinity else { return "−∞" }
        return decibels.formatted(.number.precision(.fractionLength(1)))
    }

    /// Everything that scales the signal, folded into one number: preamp trim
    /// and volume. Balance is applied per channel on top of this.
    public var outputGain: Double { preampGain * volumeGain }

    /// Per-channel gains for the balance control.
    ///
    /// Attenuates the receding side rather than boosting the advancing one:
    /// boosting would clip a track already mastered near full scale.
    public var channelGains: (left: Double, right: Double) {
        let balance = Self.clamp(self.balance, to: 1)
        return (left: min(1, 1 - balance), right: min(1, 1 + balance))
    }

    // MARK: - Boost contour
    //
    // Quiet listening loses the extremes first — the ear's sensitivity curve
    // flattens as level rises, so at low volume the bass and, less so, the
    // treble need lifting to keep the balance the mastering engineer intended.
    // The lift scales with how far the volume control has attenuated the
    // signal, and vanishes at full scale where no compensation is wanted.
    //
    // `boostDepthDecibels` is the depth knob the user sets; everything below
    // is the shape that depth is applied through, unchanged from the circuit
    // this replaces.

    /// Corner of the bass shelf.
    ///
    /// 200 Hz, not the 120 Hz this was first built with. A shelf reaches only
    /// half its gain at the corner and tapers above it, so a 120 Hz shelf is
    /// fully effective only below about 60 Hz — under most of the bass region
    /// and under what small speakers and earphones reproduce at all. The
    /// result measured correctly and was inaudible.
    public static let boostBassFrequency: Double = 200

    public static let boostTrebleFrequency: Double = 8000

    /// The knob's own travel. "Depth control, 0 to +12 dB" — bass reaches
    /// exactly this many decibels once the volume control has pulled the
    /// signal down far enough; see `boostBassDecibels`.
    public static let boostMaximumDepthDecibels: Double = 12

    /// How much less the treble shelf lifts than the bass shelf, at any
    /// depth. Carried over from the fixed circuit this replaces, which lifted
    /// bass up to 15 dB and treble up to 6 — a ratio of 0.4.
    public static let boostTrebleRatio: Double = 6.0 / 15.0

    /// Attenuation at which the contour reaches full depth.
    ///
    /// Compensation tracks sound pressure, which follows the attenuation in
    /// **decibels** — not the fader's linear position. Scaling by `(1 − volume)`
    /// was the original mistake: with a square-law fader, 70% travel is already
    /// −6 dB but only 30% of the way along the linear scale, so the contour
    /// contributed under a third of its depth exactly where it was most likely
    /// to be judged.
    /// 15 dB rather than 20: listening happens between roughly 50% and 90% of
    /// fader travel, which is −12 dB to −1 dB, so a 20 dB reference puts full
    /// depth outside the range anyone actually uses. This is a judgement call,
    /// not a standard — it is one constant to retune if it feels heavy.
    public static let boostFullCompensationDecibels: Double = 15

    /// How far the volume control has pulled the signal down, in dB, capped at
    /// the point of full compensation.
    public var volumeAttenuationDecibels: Double {
        let gain = volumeGain
        guard gain > 0 else { return Self.boostFullCompensationDecibels }
        return min(-20 * log10(gain), Self.boostFullCompensationDecibels)
    }

    /// 0 at full volume, 1 once attenuation reaches the compensation point.
    public var boostScale: Double {
        volumeAttenuationDecibels / Self.boostFullCompensationDecibels
    }

    /// The bass lift, which reaches exactly `boostDepthDecibels` once the
    /// volume control has attenuated the signal all the way to the
    /// compensation point, and nothing before the control has moved at all.
    public var boostBassDecibels: Double {
        boostScale * boostDepthDecibels
    }

    /// The shallower, proportional treble lift.
    public var boostTrebleDecibels: Double {
        boostBassDecibels * Self.boostTrebleRatio
    }

    // MARK: - Tone control
    //
    // Bass and treble shelves, separate from the graphic EQ and from the
    // boost contour. Most listeners reach for these two knobs before the
    // ten-band EQ.

    public static let toneBassFrequency: Double = 100
    public static let toneTrebleFrequency: Double = 10_000
    public static let toneMaximumDecibels: Double = 12

    /// The bass shelf gain actually reaching the chain — zero while
    /// `TONE DEFEAT` is engaged, whatever `toneBassDecibels` is set to.
    public var effectiveToneBassDecibels: Double {
        isToneDefeated ? 0 : toneBassDecibels
    }

    /// The treble shelf gain actually reaching the chain, subject to the same
    /// defeat.
    public var effectiveToneTrebleDecibels: Double {
        isToneDefeated ? 0 : toneTrebleDecibels
    }
}
